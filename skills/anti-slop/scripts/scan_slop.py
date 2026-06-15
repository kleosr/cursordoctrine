#!/usr/bin/env python3
"""scan_slop.py - static AI-slop signal scanner for the anti-slop skill.

Reports cheap, high-precision slop signals so the agent starts its de-slop sweep
from a deterministic inventory. Semantic slop (cargo-cult, superficial tests) is
deliberately NOT guessed - that stays the model's job. This seeds it.

Scopes:
  * DIFF (default): only what changed vs --base (git diff). Silent on a clean
    tree by design. Flags NEW deps, premature abstractions, redundant comments,
    AI residue (placeholder phrases / banner comments / emoji), type escapes
    (as any, as unknown as, @ts-ignore, Python type-ignore pragmas), swallowed
    errors (empty catch, broad except+pass), tautological asserts, pointless
    async wrappers (await Promise.resolve, async executors), deepening guard
    chains (the optional-chaining shape), boolean-pair call traps, SELECT *
    in .sql files, and Tailwind class soup / magic-px values. All per-file
    signals also run in AUDIT scope; only new-dependency detection is diff-only
    (every line of an existing manifest would otherwise read as "new").
  * AUDIT (--all, or explicit paths): the WHOLE codebase, with the duplication
    analysis that catches the isRecord()-class slop:
      - Clone Proliferation     : same function name in multiple files
      - Knowledge Duplication   : identical body under different names (DRY)
      - Semantic Fragmentation  : near-identical bodies (same shape, drifted
                                  names/values) - the diverged clones
      - Semantic Density Collapse: tiny helpers used 0-1 times (dead / inline)
        (--all only: reference counts over a partial file list are meaningless,
        so explicit-path scans suppress this analysis instead of guessing)
      - Generated Fingerprints  : isRecord/safeParse/sleep/retry/... repeated
      - Duplicate type/interface names across files
    Functions/methods are parsed for JS/TS, Python, Go, Rust, Ruby, PHP, and
    (best-effort) Java/Kotlin/C#/Scala.

Every duplication finding carries a confidence tier: exact (identical
normalized body) > structural (same shape, drifted names/values) > name-only
(same identifier). The report header states the scope; caps that were hit
(file list, per-file lines, per-body lines) are disclosed as notes.

Stdlib only; Python 3.9+. REPORTS only - never edits. Exits 0, except with
--gate: exit 1 when slop is found (the size-only "substantial change" note
never gates). The agent does the fixing.

Usage:
  python scripts/scan_slop.py --all --root .        # WHOLE-codebase audit (recommended)
  python scripts/scan_slop.py --root .              # diff vs HEAD (a change in progress)
  python scripts/scan_slop.py src/foo.ts src/bar.py # audit specific files
  python scripts/scan_slop.py --all --format json   # machine-readable
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from itertools import islice
from typing import Any

Finding = dict[str, Any]

# ---- per-file signal patterns -------------------------------------------
# Only manifest formats the DEP regex genuinely parses (name [:=@] version).
# go.mod / pom.xml / Gradle / Gemfile / .csproj declare deps in syntaxes DEP
# cannot match, so listing them would only over-claim coverage.
MANIFEST = re.compile(
    r"^(package\.json|requirements[\w.\-]*\.txt|pyproject\.toml|Pipfile"
    r"|Cargo\.toml|composer\.json)$"
)
DEP = re.compile(
    r"""(?:^|[{,])\s*(?:"|')?(?P<name>[A-Za-z@][\w@\-./\[\]]*)(?:"|')?\s*"""
    r"""(?:[:=]\s*(?:"|')?[\^~><=*v]?\d|[><=~!]=\s*\d|@\s*\^?\d)"""
)
# Manifest metadata that pairs a name with a version-looking value without
# declaring a dependency. Skipped only at line start: `serde = { version = ...`
# matches mid-line and IS a real dependency.
META_KEYS = frozenset({
    "version", "name", "node", "npm", "yarn", "pnpm", "packagemanager",
    "engines", "python", "private", "description",
})
ABSTRACTION = re.compile(
    r"\b(?:class|interface|struct|trait|protocol)\s+"
    r"([A-Z][A-Za-z0-9_]*(?:Factory|Repository|Mediator|Strategy|Singleton"
    r"|Facade|Builder|Visitor|Decorator|Wrapper|Orchestrator|Registry))\b"
)
# [C]QRS: the brackets change nothing semantically but keep the alternative
# from matching its own definition when the scanner audits itself.
VOCAB = re.compile(
    r"\b([C]QRS|Event[\s\-]?Sourc(?:e|ing)|Domain[\s\-]?Driven|Aggregate\s?Root"
    r"|Bounded\s?Context|Hexagonal\s+Architecture|Onion\s+Architecture)\b",
    re.I,
)
COMMENT = re.compile(
    r"^\s*(?://|#|/\*+|\*+)\s*(?:increment|decrement|loop (?:over|through)|iterate"
    r"|returns?(?: the)?(?: result| value)?\s*$|set\s+\w+\s+to\b|getter\b"
    r"|setter\b|constructor\b|initiali[sz]e\b|instantiate\b|create (?:a |an |the )"
    r"|declare\b|define\b|assign\b|end (?:of|for)\b|begin\b|start (?:of|the))",
    re.I,
)
_CMT_MARKER = re.compile(r"^\s*(?://+|#+|/\*+|\*+)\s*")
# ---- residue / type-escape / swallow / tautology signals -----------------
# Failure classes these seed: AI-Specific (prompt residue), Type-System
# (any-driven development), Defensive Code Inflation (swallowed errors) and
# Testing (test theater). \s+ between words instead of literal spaces doubles
# as robustness to spacing AND keeps each pattern from matching its own
# source when the scanner audits itself.
RESIDUE_PHRASE = re.compile(
    r"\bin\s+a\s+real\s+(?:app(?:lication)?|world|scenario)\b"
    r"|\bfor\s+production\s+use\b|\bthis\s+is\s+a\s+simplified\b"
    r"|\bTODO:?\s+implement\s+actual\b|\breplace\s+(?:this\s+)?with\s+your\b",
    re.I,
)
# = * # walls only: `# ----` section dividers are a long-standing human
# convention (numpy, stdlib); `// =====` banners are the generated-code tell.
RESIDUE_BANNER = re.compile(r"^\s*(?://|#|/\*)\s*[=*#]{5,}")
RESIDUE_EMOJI = re.compile("[\u2600-\u27bf\U0001f300-\U0001faff]")
# NOT @ts-expect-error: that one is the sanctioned, self-expiring form.
TS_SUPPRESS = re.compile(r"@ts-(?:ignore|nocheck)\b")
TS_ANY = re.compile(r"\bas\s+unknown\s+as\b|\bas\s+any\b|[,:<]\s*any\b|\bany\[\]")
PY_TYPE_ESCAPE = re.compile(r"#\s*type:\s*ignore\b")
# Only bare/broad swallows: `except ImportError: pass` is a legitimate idiom
# (optional dependency); `except Exception: pass` hides every failure.
_EXC_BROAD = r"^\s*except\b\s*(?:\(?\s*(?:Base)?Exception\s*\)?\s*(?:as\s+\w+\s*)?)?:"
PY_SWALLOW = re.compile(_EXC_BROAD + r"\s*pass\b")
PY_SWALLOW_HEAD = re.compile(_EXC_BROAD + r"\s*(?:#.*)?$")
PY_PASS = re.compile(r"^\s*pass\s*(?:#.*)?$")
JS_SWALLOW = re.compile(
    r"\bcatch\s*(?:\(\s*[^)]*\))?\s*\{\s*\}"
    r"|\.catch\(\s*(?:\(\s*\w*\s*\)|\w+)\s*=>\s*(?:\{\s*\}|null|undefined)\s*\)"
    r"|\.catch\(\s*function\s*\(\s*\w*\s*\)\s*\{\s*\}\s*\)"
)
JS_TAUTOLOGY = re.compile(
    r"\bexpect\(\s*(true|false|\d+|'[^']*'|\"[^\"]*\")\s*\)\s*\.\s*"
    r"(?:toBe|toEqual|toStrictEqual)\(\s*\1\s*\)"
    r"|\bassert(?:True)?\(\s*true\s*\)"
)
PY_TAUTOLOGY = re.compile(r"^\s*assert\s+True\s*(?:$|[,#])|\bassertTrue\(\s*True\s*\)")
# ---- framework failure modes (vibe-coding stack) --------------------------
# await Promise.resolve() is always pointless; an async promise executor
# swallows its own rejections.
ASYNC_WRAPPER = re.compile(
    r"\bawait\s+Promise\s*\.\s*resolve\s*\(|\bnew\s+Promise\s*\(\s*async\b"
)
# A lone negated guard-return; chains where each test deepens the previous
# (`!data` then `!data.user`) are the optional-chaining shape.
GUARD_RETURN = re.compile(
    r"^\s*if\s*\(\s*!\s*([\w$][\w$.]*)\s*\)\s*(?:return|continue|break)\b[^;{}]*;?\s*$"
)
# Two adjacent literal booleans inside a call's argument list (Boolean Trap).
# Bracket/brace exclusion keeps array literals like useState([true, false]) out.
BOOL_PAIR_JS = re.compile(
    r"[\w$]\s*\(\s*[^()\[\]{}]*\b(?:true|false)\s*,\s*(?:true|false)\b"
)
BOOL_PAIR_PY = re.compile(
    r"\w\s*\(\s*[^()\[\]{}]*\b(?:True|False)\s*,\s*(?:True|False)\b"
)
SELECT_STAR = re.compile(r"\bSELECT\s+\*", re.I)
TAILWIND_SOUP = re.compile(r"class(?:Name)?\s*=\s*[{]?\s*['\"`][^'\"`]{200,}")
# Arbitrary >=100px values defeat the spacing scale (w-[347px] magic numbers).
TAILWIND_MAGIC_PX = re.compile(r"-\[\d{3,}(?:\.\d+)?px\]")
SOURCE = re.compile(
    r"\.(?:ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|kts|cs|cpp|cc|cxx|c|h|hpp|rb"
    r"|php|swift|scala|m|mm|sh|ps1|lua|dart|ex|exs|vue|svelte|astro|html|sql)$"
)
CHECKLIST_LINES = 40
READ_CAP = 4000   # lines read per file
BODY_CAP = 80     # lines captured per function body
FILE_CAP = 6000   # tracked files scanned in --all
SHOW_CAP = 10     # findings printed per list (counts stay exact)

# ---- duplication / clone machinery --------------------------------------
ID = re.compile(r"[A-Za-z_$][\w$]*")
TYPE_DECL = re.compile(r"\b(?:type|interface)\s+([A-Z][A-Za-z0-9_]*)\b")
MICRO_PREFIX = re.compile(
    r"^(?:is|has|can|should|assert|ensure|safe|to|from|get|set|make|create"
    r"|parse|format|with|map|build|validate)[A-Z0-9]"
)
COMMON_NAMES = {
    "render", "main", "default", "index", "setup", "run", "start", "stop",
    "init", "handler", "handle", "callback", "loader", "action", "middleware",
    "reducer", "app", "page", "layout", "constructor", "tostring", "tojson",
    "valueof", "equals", "dispose", "close", "open", "connect", "get", "set",
    "update", "create", "delete", "list", "find", "save", "load", "execute",
    "process", "build", "test", "describe", "it", "expect", "beforeeach",
    "aftereach", "beforeall", "afterall", "getstaticprops", "getserversideprops",
    "getstaticpaths", "generatemetadata", "usestate", "useeffect", "wrapper",
    "new", "string", "tostr", "clone", "copy", "value", "data", "result",
    "componentdidmount", "componentwillunmount", "componentdidupdate",
    "componentdidcatch", "getderivedstatefromerror", "getderivedstatefromprops",
    "shouldcomponentupdate", "getsnapshotbeforeupdate", "ngoninit", "ngondestroy",
    "connectedcallback", "disconnectedcallback",
}
# Common per-module type names - excluded from type-duplication reporting.
COMMON_TYPES = frozenset({
    "props", "state", "options", "option", "params", "parameters", "result",
    "config", "configuration", "context", "ctx", "data", "item", "items",
    "response", "request", "error", "react", "window", "ref", "children",
    "theme", "style", "styles", "value", "values", "model", "entity", "dto",
    "payload", "meta", "args", "arg", "input", "output", "node", "element",
    "key", "id", "type", "types", "field", "fields", "row", "column", "event",
    "handler", "callback", "fn", "cb",
})
FINGERPRINTS = {
    "isrecord", "isobject", "isplainobject", "isdictionary", "isstring",
    "isnumber", "isboolean", "isarraylike", "isnil", "isempty", "isdefined",
    "ensurearray", "assertarray", "safeparse", "safeparsejson", "safejsonparse",
    "sleep", "delay", "retry", "assertnever", "deepclone", "deepequal", "noop",
    "clamp", "uniq", "unique", "capitalize", "classnames", "cn", "tryparse",
}
# Only genuine structural/control-flow keywords. Deliberately EXCLUDES words that
# are commonly variable/method names in other languages (val, map, go, select,
# ...) - masking those would break the structural hash (val stays val while value
# becomes I -> false-negative near-dups).
KEYWORDS = frozenset({
    "if", "else", "elif", "for", "while", "do", "switch", "case", "default",
    "break", "continue", "return", "function", "func", "fn", "def", "class",
    "struct", "interface", "type", "trait", "impl", "enum", "const", "let",
    "var", "new", "delete", "typeof", "instanceof", "in", "of", "is",
    "as", "not", "and", "or", "null", "nil", "none", "None", "true", "false",
    "True", "False", "undefined", "void", "this", "self", "super", "yield",
    "await", "async", "try", "catch", "except", "finally", "throw", "raise",
    "with", "public", "private", "protected", "static", "import",
    "from", "export", "package", "lambda", "pass", "end",
})
# Class-method signature (JS/TS + best-effort C-style); names that are really
# control flow are filtered out after match.
METHOD_JS = re.compile(
    r"^\s*(?:public\s+|private\s+|protected\s+|static\s+|readonly\s+|async\s+"
    r"|get\s+|set\s+|override\s+|\*\s*)*([A-Za-z_$][\w$]*)\s*\([^;{]*\)\s*"
    r"(?::\s*[^={;]+)?\s*\{"
)
METHOD_CSTYLE = re.compile(
    r"^\s*(?:(?:public|private|protected|internal|static|final|virtual|override"
    r"|abstract|async|sealed|unsafe)\s+)+[\w<>\[\].,?]+\s+([A-Za-z_]\w*)\s*"
    r"\([^;{]*\)\s*(?:where[^{]+)?\{"
)
NOT_METHOD = {
    "if", "for", "while", "switch", "catch", "return", "function", "do",
    "else", "with", "await", "new", "delete", "void", "yield", "case",
    "throw", "super", "typeof", "using", "lock", "fixed", "foreach",
}
EXPORT_KEYWORD = re.compile(r"\b(?:export|public|pub)\b")
FUNC_PATTERNS = {
    "js": [
        re.compile(r"(?:^|\s)(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\("),
        re.compile(r"(?:^|\s)(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"),
        METHOD_JS,
    ],
    "py": [re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(")],
    "go": [re.compile(r"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(")],
    "rust": [re.compile(r"\bfn\s+([A-Za-z_]\w*)\s*[(<]")],
    "ruby": [re.compile(r"^\s*def\s+(?:self\.)?([A-Za-z_]\w*[!?=]?)")],
    "php": [re.compile(r"\bfunction\s+([A-Za-z_]\w*)\s*\(")],
    "cstyle": [METHOD_CSTYLE],
}

# ---- comment/string tokenization (language-aware, single pass) -----------
# One combined regex per language family, string alternatives FIRST, so a //
# or # inside a string literal can never be amputated as a comment, and an
# unbalanced quote left by comment-stripping can never swallow real code.
# Known line-based blind spots (accepted for zero deps): JS regex literals,
# Rust lifetimes ('a), raw strings ending in a backslash.
_STR_DQ = r'"(?:[^"\\\n]|\\.)*"'
_STR_SQ = r"'(?:[^'\\\n]|\\.)*'"
_STR_BT = r"`(?:[^`\\]|\\.)*`"
_STR_TRIPLE = r"'''(?s:.*?)'''|\"\"\"(?s:.*?)\"\"\""
_CMT_SLASH = r"//[^\n]*"
_CMT_HASH = r"#[^\n]*"
_CMT_BLOCK = r"/\*(?s:.*?)\*/"
_FAMILY_SYNTAX = {
    # family: (string alternatives, comment alternatives)
    "py":   (f"{_STR_TRIPLE}|{_STR_DQ}|{_STR_SQ}", _CMT_HASH),
    "ruby": (f"{_STR_DQ}|{_STR_SQ}", _CMT_HASH),
    "php":  (f"{_STR_DQ}|{_STR_SQ}", f"{_CMT_SLASH}|{_CMT_BLOCK}|{_CMT_HASH}"),
    "bt":   (f"{_STR_BT}|{_STR_DQ}|{_STR_SQ}", f"{_CMT_SLASH}|{_CMT_BLOCK}"),
    "c":    (f"{_STR_DQ}|{_STR_SQ}", f"{_CMT_SLASH}|{_CMT_BLOCK}"),
}
_LANG_FAMILY = {"py": "py", "ruby": "ruby", "php": "php", "js": "bt", "go": "bt"}
_TOKEN_RX = {
    fam: re.compile(f"(?P<s>{strs})|(?P<c>{cmts})")
    for fam, (strs, cmts) in _FAMILY_SYNTAX.items()
}


def _strip_comments(text: str, lang: str, string_repl: str | None) -> str:
    """Drop comments for `lang`; keep strings verbatim (string_repl=None) or
    mask each one with string_repl."""
    rx = _TOKEN_RX[_LANG_FAMILY.get(lang, "c")]

    def repl(m: re.Match[str]) -> str:
        if m.lastgroup == "s":
            return m.group(0) if string_repl is None else string_repl
        return " "

    return rx.sub(repl, text)


def _mask_strings(text: str, lang: str) -> str:
    """Mask string-literal contents but KEEP comments. For detectors whose
    habitat is comments/code (residue phrases, boolean call args): a slop
    phrase *quoted in a string* is a fixture or UI copy - the model pass
    judges those in context, the scanner must not."""
    rx = _TOKEN_RX[_LANG_FAMILY.get(lang, "c")]
    return rx.sub(lambda m: "L" if m.lastgroup == "s" else m.group(0), text)


def lang_of(rel: str) -> str:
    ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
    if ext == "py":
        return "py"
    if ext == "go":
        return "go"
    if ext == "rs":
        return "rust"
    if ext == "rb":
        return "ruby"
    if ext == "php":
        return "php"
    if ext in ("java", "kt", "kts", "cs", "scala"):
        return "cstyle"
    if ext in ("ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "astro"):
        return "js"
    return "other"


def git(root: str, *args: str) -> str | None:
    # quotepath=false: git would otherwise octal-escape non-ASCII paths and the
    # escaped name would never open. UTF-8 decode: text=True would use the
    # locale codec (cp1252 on Windows) and crash on real UTF-8 diffs.
    try:
        p = subprocess.run(
            ["git", "-C", root, "-c", "core.quotepath=false", *args],
            capture_output=True, encoding="utf-8", errors="replace",
        )
    except OSError:
        return None
    return p.stdout if p.returncode == 0 else ""


def _unquote_path(p: str) -> str:
    """Undo git's C-style quoting of paths with quotes/specials (rare once
    core.quotepath=false handles non-ASCII)."""
    if len(p) >= 2 and p.startswith('"') and p.endswith('"'):
        return re.sub(
            r"\\(.)",
            lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)),
            p[1:-1],
        )
    return p


def parse_added_by_file(diff_text: str) -> dict[str, list[str]]:
    """Added lines per file from ONE `git diff` run (not one process per file)."""
    added: dict[str, list[str]] = {}
    cur: str | None = None
    for ln in diff_text.splitlines():
        if ln.startswith("+++ "):
            path = _unquote_path(ln[4:].strip())
            if path == "/dev/null":
                cur = None
            else:
                cur = path[2:] if path.startswith("b/") else path
        elif cur is not None and ln.startswith("+") and not ln.startswith("+++"):
            added.setdefault(cur, []).append(ln[1:])
    return added


def read_whole(root: str, rel: str) -> tuple[list[str] | None, bool]:
    """First READ_CAP lines and whether the file had more (truncated).
    None = unreadable (missing/permission); callers must surface it, because a
    silent skip turns a vanished file into a false 'no slop found'."""
    try:
        # utf-8-sig: PowerShell writes BOMs by default; a surviving \ufeff on
        # line 1 would defeat every ^-anchored detector.
        with open(os.path.join(root, rel), encoding="utf-8-sig", errors="ignore") as fh:
            lines = [ln.rstrip("\n") for ln in islice(fh, READ_CAP + 1)]
    except OSError:
        return None, False
    if len(lines) > READ_CAP:
        return lines[:READ_CAP], True
    return lines, False


def _read_for_scan(root: str, rel: str, unreadable: list[str]) -> tuple[list[str], bool]:
    lines, truncated = read_whole(root, rel)
    if lines is None:
        unreadable.append(rel)
        return [], False
    return lines, truncated


def _uniq(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for it in items:
        if it not in seen:
            seen.add(it)
            out.append(it)
    return out


def is_redundant_comment(line: str) -> bool:
    if not COMMENT.search(line):
        return False
    body = re.sub(r"\*/\s*$", "", _CMT_MARKER.sub("", line)).strip()
    return len(body.split()) <= 6


def _dep_line_hit(ln: str) -> bool:
    for m in DEP.finditer(ln):
        # Line-start metadata ("version": "2.1.0") is a manifest field, not a dep.
        if m.start() == 0 and m.group("name").lower() in META_KEYS:
            continue
        return True
    return False


# Every per-file slop signal scan_lines emits, with its report label (padded
# to one column) and summary label. Gate, totals, and printing derive from
# this one table.
_SIGNALS = {
    "dependencies":       ("new dependency       ", "dep"),
    "abstractions":       ("premature abstraction", "abstraction"),
    "redundant_comments": ("redundant comment    ", "redundant-comment"),
    "ai_residue":         ("AI residue           ", "residue"),
    "type_escapes":       ("type escape          ", "type-escape"),
    "swallowed_errors":   ("swallowed error      ", "swallowed-error"),
    "tautological_tests": ("tautological test    ", "tautology"),
    "async_wrappers":     ("async wrapper        ", "async-wrapper"),
    "guard_chains":       ("guard chain (use ?.) ", "guard-chain"),
    "boolean_traps":      ("boolean trap         ", "boolean-trap"),
    "select_star":        ("SELECT *             ", "select-star"),
    "tailwind_slop":      ("tailwind smell       ", "tailwind"),
}
_SIGNAL_KEYS = tuple(_SIGNALS)


def _file_slop(r: Finding) -> bool:
    return any(r[k] for k in _SIGNAL_KEYS)


def scan_lines(rel: str, lines: list[str], audit: bool) -> Finding | None:
    if not lines:
        return None
    lang = lang_of(rel)
    ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
    is_source = bool(SOURCE.search(rel))
    found: dict[str, list[str]] = {k: [] for k in _SIGNAL_KEYS}
    check_deps = (not audit) and bool(MANIFEST.search(os.path.basename(rel)))
    for i, ln in enumerate(lines):
        # Dep detection reads raw lines: in manifests the strings ARE the data.
        if check_deps and _dep_line_hit(ln):
            found["dependencies"].append(ln.strip()[:100])
        # Comment-habitat detectors run on the string-masked line (comments
        # kept): a slop pattern *quoted in a string* is a fixture, a log
        # message, or UI copy - context for the model pass, not the scanner.
        masked = _mask_strings(ln, lang)
        # Code signals only apply to source files: pattern vocabulary inside
        # markdown prose is documentation, not an abstraction. (Deps stay
        # separate - manifests are not SOURCE files.)
        if is_source:
            m = ABSTRACTION.search(masked)
            if m:
                found["abstractions"].append(m.group(1))
            else:
                v = VOCAB.search(masked)
                if v:
                    found["abstractions"].append(v.group(1))
            if is_redundant_comment(masked):
                found["redundant_comments"].append(ln.strip()[:100])
            # Banner/emoji stay on the raw line (a celebration emoji in
            # user-facing copy IS the slop).
            if (RESIDUE_PHRASE.search(masked) or RESIDUE_BANNER.match(ln)
                    or RESIDUE_EMOJI.search(ln)):
                found["ai_residue"].append(ln.strip()[:100])
        if lang in ("js", "cstyle", "php"):
            # Mask strings + comments first: `as any` and `catch {}` are also
            # English prose / string content.
            code = _strip_comments(ln, lang, "L")
            if lang == "js" and (
                TS_SUPPRESS.search(masked)
                or (not _CMT_MARKER.match(ln) and TS_ANY.search(code))
            ):
                found["type_escapes"].append(ln.strip()[:100])
            if JS_SWALLOW.search(code):
                found["swallowed_errors"].append(ln.strip()[:100])
            # Raw line: the string-literal tautology alternative needs the
            # actual quotes, which masking would erase.
            if JS_TAUTOLOGY.search(ln):
                found["tautological_tests"].append(ln.strip()[:100])
            if BOOL_PAIR_JS.search(code):
                found["boolean_traps"].append(ln.strip()[:100])
            if lang == "js":
                if ASYNC_WRAPPER.search(code):
                    found["async_wrappers"].append(ln.strip()[:100])
                gm = GUARD_RETURN.match(ln)
                if gm and i + 1 < len(lines):
                    nxt = GUARD_RETURN.match(lines[i + 1])
                    if nxt and nxt.group(1).startswith(gm.group(1) + "."):
                        found["guard_chains"].append(ln.strip()[:100])
        elif lang == "py":
            if PY_TYPE_ESCAPE.search(masked):
                found["type_escapes"].append(ln.strip()[:100])
            if PY_SWALLOW.match(ln) or (
                PY_SWALLOW_HEAD.match(ln)
                and i + 1 < len(lines) and PY_PASS.match(lines[i + 1])
            ):
                found["swallowed_errors"].append(ln.strip()[:100])
            if PY_TAUTOLOGY.search(ln):
                found["tautological_tests"].append(ln.strip()[:100])
            if BOOL_PAIR_PY.search(masked):
                found["boolean_traps"].append(ln.strip()[:100])
        if ext == "sql" and not ln.lstrip().startswith("--") and SELECT_STAR.search(ln):
            found["select_star"].append(ln.strip()[:100])
        if (lang == "js" or ext == "html") and (
            TAILWIND_SOUP.search(ln) or TAILWIND_MAGIC_PX.search(ln)
        ):
            found["tailwind_slop"].append(ln.strip()[:100])
    found = {k: _uniq(v) for k, v in found.items()}
    added_count = sum(1 for ln in lines if ln.strip())
    substantial = (not audit) and is_source and added_count >= CHECKLIST_LINES
    if not (any(found.values()) or substantial):
        return None
    out: Finding = {"file": rel, "added_lines": added_count,
                    "substantial": substantial}
    out.update(found)
    return out


# ---- body capture + hashing ---------------------------------------------
def _indent(s: str) -> int:
    return len(s) - len(s.lstrip())


def capture_body(lines: list[str], start_idx: int, lang: str) -> tuple[str, bool]:
    """Body text and whether capture hit the BODY_CAP window (truncated)."""
    if lang in ("py", "ruby"):
        base = _indent(lines[start_idx])
        window = lines[start_idx + 1:start_idx + 1 + BODY_CAP]
        out: list[str] = []
        for ln in window:
            if lang == "py" and ln.strip() and _indent(ln) <= base:
                break
            if lang == "ruby" and ln.strip() == "end" and _indent(ln) <= base:
                break
            out.append(ln)
        else:
            return "\n".join(out), len(lines) > start_idx + 1 + BODY_CAP
        return "\n".join(out), False
    # brace languages
    sig = lines[start_idx]
    arrow = sig.find("=>")
    if arrow >= 0 and sig.find("{", arrow) < 0:
        return sig[arrow + 2:].split(";")[0], False
    brace_line = -1
    for k in range(start_idx, min(start_idx + 6, len(lines))):
        if "{" in lines[k]:
            brace_line = k
            break
        if ";" in lines[k] and "=>" not in lines[k]:
            return "", False
    if brace_line < 0:
        return "", False
    depth, started = 0, False
    out_chars: list[str] = []
    for ln in lines[brace_line:brace_line + 1 + BODY_CAP]:
        for ch in ln:
            if ch == "{":
                depth += 1
                if depth == 1:
                    started = True
                    continue
            elif ch == "}":
                depth -= 1
                if depth == 0 and started:
                    return "".join(out_chars), False
            if started:
                out_chars.append(ch)
        if started:
            out_chars.append("\n")
    # Never saw the closing brace inside the window: cap hit (or EOF mid-body).
    return "".join(out_chars), True


def normalize_body(text: str, lang: str) -> str:
    """Whitespace/comment-insensitive but literal-sensitive text, for the
    exact-duplicate hash. Strings survive verbatim (URLs differ => bodies differ)."""
    text = _strip_comments(text, lang, string_repl=None)
    return re.sub(r"\s+", " ", text).strip()


def structural_body(text: str, lang: str) -> str:
    """Mask identifiers + literals; keep keywords/operators. Two bodies with the
    same control-flow shape but drifted names/values hash equal => near-duplicate."""
    text = _strip_comments(text, lang, string_repl="L")
    text = re.sub(r"\b\d[\w.]*\b", "N", text)
    text = ID.sub(lambda m: m.group(0) if m.group(0) in KEYWORDS else "I", text)
    return re.sub(r"\s+", "", text)


def _digest(s: str) -> str:
    # blake2b, not md5: FIPS-enabled Pythons refuse md5 outright.
    return hashlib.blake2b(s.encode("utf-8"), digest_size=16).hexdigest()


def _is_exported(name: str, line: str, lang: str) -> bool:
    if lang == "py":
        return not name.startswith("_")     # public def: importable anywhere
    if lang == "go":
        return name[:1].isupper()           # Go exports by capitalization
    return (bool(EXPORT_KEYWORD.search(line))
            or "module.exports" in line or "exports." in line)


def collect_defs(rel: str, lines: list[str]) -> list[Finding]:
    lang = lang_of(rel)
    decls = FUNC_PATTERNS.get(lang)
    if not decls:
        return []
    defs: list[Finding] = []
    for i, ln in enumerate(lines):
        name = None
        for rx in decls:
            m = rx.search(ln)
            if m:
                cand = m.group(1)
                if rx in (METHOD_JS, METHOD_CSTYLE) and cand in NOT_METHOD:
                    continue
                name = cand
                break
        if not name:
            continue
        raw, truncated = capture_body(lines, i, lang)
        nb = normalize_body(raw, lang)
        sb = structural_body(raw, lang)
        # Non-blank lines only: the brace walk pads raw with edge newlines,
        # and counting them would let `super(props);` pad its body_line count.
        body_lines = sum(1 for s in raw.splitlines() if s.strip()) or 1
        # Exact-dup hash needs substance (>=12 normalized chars). An earlier
        # >=3-lines-or->=60-chars floor excluded the skill's own marquee case -
        # tiny predicates like isRecord/isObject (1 line, ~40 chars) whose
        # byte-identical bodies are exactly the duplication worth surfacing.
        # Boilerplate like `return;`/`return x;` stays under the 12-char floor.
        # A truncated body is a prefix, not the function - never call it exact.
        hash_exact = (not truncated and len(nb) >= 12)
        defs.append({
            "name": name, "file": rel, "line": i + 1,
            "exported": _is_exported(name, ln, lang),
            "exact": _digest(nb) if hash_exact else None,
            "struct": _digest(sb) if len(sb) >= 20 else None,  # skip trivial one-liners (return I;)
            "body_lines": body_lines,
            "truncated": truncated,
        })
    return defs


def collect_types(rel: str, lines: list[str]) -> list[Finding]:
    if lang_of(rel) != "js":
        return []
    out: list[Finding] = []
    for ln in lines:
        m = TYPE_DECL.search(ln)
        if m:
            out.append({"name": m.group(1), "file": rel})
    return out


def analyze_duplication(defs: list[Finding], types: list[Finding],
                        idfreq: Counter[str], full_scope: bool) -> Finding:
    by_name: dict[str, list[Finding]] = defaultdict(list)
    by_exact: dict[str, list[Finding]] = defaultdict(list)
    by_struct: dict[str, list[Finding]] = defaultdict(list)
    name_def_counts: Counter[str] = Counter()
    for d in defs:
        by_name[d["name"]].append(d)
        name_def_counts[d["name"]] += 1
        if d["exact"]:
            by_exact[d["exact"]].append(d)
        if d["struct"]:
            by_struct[d["struct"]].append(d)

    name_clones = []
    for name, ds in by_name.items():
        files = sorted({d["file"] for d in ds})
        if len(files) >= 2 and name.lower() not in COMMON_NAMES:
            name_clones.append({"name": name, "count": len(ds), "files": files,
                                "confidence": "name-only"})
    name_clones.sort(key=lambda x: -x["count"])

    body_clones = []
    for ds in by_exact.values():
        names = sorted({d["name"] for d in ds})
        files = sorted({d["file"] for d in ds})
        if len(ds) >= 2 and (len(files) >= 2 or len(names) >= 2):
            body_clones.append({"names": names, "files": files, "count": len(ds),
                                "confidence": "exact"})
    body_clones.sort(key=lambda x: -x["count"])

    near_clones = []
    for ds in by_struct.values():
        exacts = {d["exact"] for d in ds if d["exact"]}
        if len(ds) >= 2 and len(exacts) >= 2:  # same shape, genuinely different bodies
            names = sorted({d["name"] for d in ds})
            files = sorted({d["file"] for d in ds})
            near_clones.append({"names": names, "files": files, "count": len(ds),
                                "confidence": "structural"})
    near_clones.sort(key=lambda x: -x["count"])

    # Reference counts only mean something when every file was scanned; on a
    # partial file list "0 references" is an artifact of the scope, and acting
    # on it would delete live code.
    single_use: list[Finding] = []
    if full_scope:
        seen_su: set[str] = set()
        for d in defs:
            name = d["name"]
            if name in seen_su or name.lower() in COMMON_NAMES:
                continue
            small = d["body_lines"] <= 3
            util_ish = bool(MICRO_PREFIX.search(name)) or name.lower() in FINGERPRINTS
            if not (small or util_ish):
                continue
            # Export-aware: exported defs may be public API / framework entry
            # points, so we can't call them dead. Only judge repo-internal defs.
            if d.get("exported"):
                continue
            refs = idfreq.get(name, 0) - name_def_counts[name]
            if refs == 0:
                seen_su.add(name)
                single_use.append({"name": name, "file": d["file"], "kind": "dead"})
            elif refs == 1 and util_ish:
                seen_su.add(name)
                single_use.append({"name": name, "file": d["file"], "kind": "inline"})

    fp: dict[str, int] = defaultdict(int)
    for d in defs:
        if d["name"].lower() in FINGERPRINTS:
            fp[d["name"]] += 1
    micro = sum(1 for d in defs if MICRO_PREFIX.search(d["name"]) and d["body_lines"] <= 3)

    type_files: dict[str, set[str]] = defaultdict(set)
    for t in types:
        type_files[t["name"]].add(t["file"])
    type_clones = [{"name": n, "files": sorted(fs), "confidence": "name-only"}
                   for n, fs in type_files.items()
                   if len(fs) >= 2 and n.lower() not in COMMON_TYPES]

    return {"name_clones": name_clones, "body_clones": body_clones,
            "near_clones": near_clones, "single_use": single_use,
            "type_clones": type_clones, "fingerprints": dict(sorted(fp.items(), key=lambda x: -x[1])),
            "micro_count": micro, "total_defs": len(defs),
            "truncated_defs": sum(1 for d in defs if d["truncated"])}


def target_files(root: str, base: str, paths: list[str], is_git: bool,
                 all_mode: bool) -> tuple[list[str], set[str], bool]:
    """(files to scan, untracked subset, hit-the-FILE_CAP flag)."""
    if paths:
        return [p.replace("\\", "/") for p in paths], set(), False
    if not is_git:
        return [], set(), False
    if all_mode:
        tracked = (git(root, "ls-files") or "").splitlines()
        srcs = [_unquote_path(f.strip()) for f in tracked
                if f.strip() and SOURCE.search(_unquote_path(f.strip()))]
        return srcs[:FILE_CAP], set(), len(srcs) > FILE_CAP
    names = (git(root, "diff", "--name-only", base) or "").splitlines()
    others = (git(root, "ls-files", "--others", "--exclude-standard") or "").splitlines()
    untracked = {_unquote_path(f.strip()) for f in others if f.strip()}
    seen: set[str] = set()
    out: list[str] = []
    for f in names + others:
        f = _unquote_path(f.strip())
        if f and f not in seen:
            seen.add(f)
            out.append(f)
    return out, untracked, False


def _dup_has_findings(dup: Finding | None) -> bool:
    if not dup:
        return False
    return bool(dup["name_clones"] or dup["body_clones"] or dup["near_clones"]
                or dup["single_use"] or dup["type_clones"] or dup["fingerprints"]
                or dup["micro_count"])


def _print_capped(label: str, items: list[str]) -> None:
    for it in items[:SHOW_CAP]:
        print(f"  {label}: {it}")
    if len(items) > SHOW_CAP:
        print(f"  ... +{len(items) - SHOW_CAP} more {label.strip()}")


def _print_duplication(dup: Finding) -> bool:
    nc, bc, near, su = dup["name_clones"], dup["body_clones"], dup["near_clones"], dup["single_use"]
    tc, fp = dup["type_clones"], dup["fingerprints"]
    if not _dup_has_findings(dup):
        return False
    print("DUPLICATION (whole-codebase - the isRecord-class slop):")
    if nc:
        print("  Clone proliferation - same function name in multiple files [confidence: name-only]:")
        for c in nc[:15]:
            print(f"    {c['name']:<22} x{c['count']:<3} {', '.join(c['files'][:6])}")
    if bc:
        print("  Knowledge duplication - identical body, consolidate to ONE (DRY) [confidence: exact]:")
        for c in bc[:15]:
            print(f"    [{'/'.join(c['names'][:4])}] x{c['count']} across {', '.join(c['files'][:5])}")
    if near:
        print("  Semantic fragmentation - near-identical bodies (drifted clones) [confidence: structural]:")
        for c in near[:12]:
            print(f"    [{'/'.join(c['names'][:4])}] x{c['count']} across {', '.join(c['files'][:5])}")
    if su:
        print("  Semantic density collapse - dead / single-use helpers:")
        for c in su[:15]:
            tag = "unused & not exported -> delete" if c["kind"] == "dead" else "used once -> inline"
            print(f"    {c['name']:<24} {tag:<32} {c['file']}")
    if tc:
        print("  Duplicate type/interface names [confidence: name-only]:")
        for c in tc[:10]:
            print(f"    {c['name']:<22} {', '.join(c['files'][:6])}")
    if fp:
        print("  Generated-code fingerprints present: "
              + ", ".join(f"{k}({v})" for k, v in list(fp.items())[:12]))
    if dup["micro_count"]:
        print(f"  Micro-abstraction load: {dup['micro_count']} tiny is*/assert*/safe* "
              f"helpers of {dup['total_defs']} defs (Helper Hell risk)")
    print("  -> Consolidate clones to one shared definition, inline single-use helpers,")
    print("     re-point imports, delete the rest. One source of truth per concept.\n")
    return True


def main() -> int:
    # A cp1252 pipe (Windows capture) must degrade, not crash, on the
    # non-ASCII paths core.quotepath=false deliberately preserves.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description="Static AI-slop signal scanner (reports only).")
    ap.add_argument("paths", nargs="*", help="specific files to audit (default: the git diff)")
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--base", default="HEAD", help="git ref to diff against in diff scope")
    ap.add_argument("--all", action="store_true", help="audit ALL tracked source files + duplication")
    ap.add_argument("--gate", action="store_true",
                    help="exit non-zero if slop is found, in any output format "
                         "(the size-only 'substantial' note never gates)")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    is_git = bool(git(root, "rev-parse", "--git-dir"))
    audit = args.all or bool(args.paths)
    full_scope = args.all and not args.paths
    files, untracked, files_capped = target_files(root, args.base, args.paths, is_git, args.all)

    warnings: list[str] = []
    if files_capped:
        warnings.append(f"file list capped at {FILE_CAP} tracked source files; scan is partial")
    if audit and not full_scope:
        warnings.append("partial scope (explicit paths): single-use/dead-helper analysis "
                        "suppressed - reference counts need the whole codebase (--all)")

    file_lines: dict[str, list[str]] = {}
    read_capped: list[str] = []
    unreadable: list[str] = []
    if audit:
        for f in files:
            lines, truncated = _read_for_scan(root, f, unreadable)
            file_lines[f] = lines
            if truncated:
                read_capped.append(f)
    else:
        # User diff.noprefix / diff.mnemonicPrefix config would change the
        # +++ headers and silently break the b/ stripping in the parser.
        diff_added = parse_added_by_file(
            git(root, "-c", "diff.noprefix=false", "-c", "diff.mnemonicprefix=false",
                "diff", args.base) or "") if is_git else {}
        for f in files:
            if f in untracked:
                lines, truncated = _read_for_scan(root, f, unreadable)
                file_lines[f] = lines
                if truncated:
                    read_capped.append(f)
            else:
                file_lines[f] = diff_added.get(f, [])
    if read_capped:
        shown = ", ".join(read_capped[:5]) + (" ..." if len(read_capped) > 5 else "")
        warnings.append(f"{len(read_capped)} file(s) hit the {READ_CAP}-line read cap "
                        f"(tail unscanned): {shown}")
    if unreadable:
        shown = ", ".join(unreadable[:5]) + (" ..." if len(unreadable) > 5 else "")
        warnings.append(f"{len(unreadable)} file(s) could NOT be read and were NOT "
                        f"scanned (missing or unreadable): {shown}")

    results = [r for r in (scan_lines(f, ls, audit) for f, ls in file_lines.items()) if r]

    dup: Finding | None = None
    if audit:
        idfreq: Counter[str] = Counter()
        defs: list[Finding] = []
        types: list[Finding] = []
        for f, ls in file_lines.items():
            for ln in ls:
                idfreq.update(ID.findall(ln))
            defs.extend(collect_defs(f, ls))
            types.extend(collect_types(f, ls))
        dup = analyze_duplication(defs, types, idfreq, full_scope)
        if dup["truncated_defs"]:
            warnings.append(f"{dup['truncated_defs']} function bodies hit the {BODY_CAP}-line "
                            "capture cap; excluded from exact-duplicate hashing")
    mode = "audit" if audit else "diff"
    scope = ("explicit paths" if args.paths
             else "whole codebase (--all)" if args.all
             else f"diff vs {args.base}")

    totals: dict[str, int] = {k: sum(len(r[k]) for r in results)
                              for k in _SIGNAL_KEYS}
    totals["files"] = len(results)

    # The gate trips on slop only. "Substantial" is a checklist nudge for big
    # clean changes, not a defect - a clean 40-line diff must pass.
    slop_found = any(_file_slop(r) for r in results) or _dup_has_findings(dup)
    exit_code = 1 if args.gate and slop_found else 0

    if args.format == "json":
        print(json.dumps({"mode": mode, "scope": scope, "base": args.base, "git": is_git,
                          "files_scanned": len(files), "totals": totals,
                          "slop_found": slop_found, "warnings": warnings,
                          "files": results, "duplication": dup}, indent=2))
        return exit_code

    if not is_git and not args.paths:
        print("anti-slop scan: not a git repo and no paths given.")
        print("Audit files: `scan_slop.py src/foo.ts`, or run inside a git repo with --all.")
        return 0

    print(f"anti-slop scan - scope: {scope}, {len(files)} file(s)\n")
    for w in warnings:
        print(f"  note: {w}")
    if warnings:
        print()

    has_dup = bool(dup and _print_duplication(dup))

    if results:
        print(f"{totals['files']} file(s) with per-file signals\n")
        for r in results:
            print(r["file"])
            for key, (label, _short) in _SIGNALS.items():
                _print_capped(label, r[key])
            if r["substantial"] and not _file_slop(r):
                print(f"  +{r['added_lines']} added lines (>= {CHECKLIST_LINES}: run the checklist)")
            print()

    if not results and not has_dup:
        if audit:
            print(f"No static slop patterns across {len(files)} file(s).")
            print("Clean of the deterministic signals. Semantic slop still needs a model pass:")
            print("invoke the anti-slop skill for edge cases / superficial tests / cargo-cult.")
        elif not files:
            print(f"Nothing changed vs {args.base} (clean working tree).")
            print("Diff scope only vets a change in progress. To review existing code:")
            print("  scan_slop.py --all          (whole codebase + duplication)")
            print("  scan_slop.py path/to/file   (specific files)")
        else:
            print(f"{len(files)} changed file(s) scanned - no static slop signals.")
            print("Semantic slop still needs a model pass; walk the SKILL.md taxonomy.")
        if args.gate:
            print("GATE: PASS (no slop)")
        return exit_code

    parts = [f"{totals[k]} {short}" for k, (_label, short) in _SIGNALS.items()
             if totals[k]]
    print(f"SUMMARY ({mode}): "
          + (", ".join(parts) if parts else "no per-file slop signals"), end="")
    if dup:
        print(f"; {len(dup['name_clones'])} name-clone, {len(dup['body_clones'])} exact-dup, "
              f"{len(dup['near_clones'])} near-dup, {len(dup['single_use'])} single-use", end="")
    print(".")
    if slop_found:
        print("Fix every signal above, then walk the full taxonomy in SKILL.md and re-scan (expect clean).")
    if args.gate:
        print("GATE: FAIL (slop found)" if slop_found else "GATE: PASS (no slop)")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
