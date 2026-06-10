#!/usr/bin/env python3
"""scan_slop.py - static AI-slop signal scanner for the anti-slop skill.

Reports cheap, high-precision slop signals so the agent starts its de-slop sweep
from a deterministic inventory. Semantic slop (cargo-cult, superficial tests) is
deliberately NOT guessed - that stays the model's job. This seeds it.

Scopes:
  * DIFF (default): only what changed vs --base (git diff). Silent on a clean
    tree by design. Flags NEW deps, premature abstractions, redundant comments.
  * AUDIT (--all, or explicit paths): the WHOLE codebase, with the duplication
    analysis that catches the isRecord()-class slop:
      - Clone Proliferation     : same function name in multiple files
      - Knowledge Duplication   : identical body under different names (DRY)
      - Semantic Fragmentation  : near-identical bodies (same shape, drifted
                                  names/values) - the diverged clones
      - Semantic Density Collapse: tiny helpers used 0-1 times (dead / inline)
      - Generated Fingerprints  : isRecord/safeParse/sleep/retry/... repeated
      - Duplicate type/interface names across files
    Functions/methods are parsed for JS/TS, Python, Go, Rust, Ruby, PHP, and
    (best-effort) Java/Kotlin/C#/Scala.

Stdlib only; Python 3.8+ (Cursor, OpenCode, CI). REPORTS only - never edits,
never blocks, always exits 0. The agent does the fixing.

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

# ---- per-file signal patterns -------------------------------------------
MANIFEST = re.compile(
    r"^(package\.json|requirements[\w.\-]*\.txt|pyproject\.toml|Pipfile|go\.mod"
    r"|Cargo\.toml|Gemfile|composer\.json|pom\.xml|build\.gradle(?:\.kts)?"
    r"|packages\.config)$|\.csproj$"
)
DEP = re.compile(
    r"""(?:^|[{,])\s*(?:"|')?[A-Za-z@][\w@\-./\[\]]*(?:"|')?\s*"""
    r"""(?:[:=]\s*(?:"|')?[\^~><=*v]?\d|[><=~!]=\s*\d|@\s*\^?\d)"""
)
ABSTRACTION = re.compile(
    r"\b(?:class|interface|struct|trait|protocol)\s+"
    r"([A-Z][A-Za-z0-9_]*(?:Factory|Repository|Mediator|Strategy|Singleton"
    r"|Facade|Builder|Visitor|Decorator))\b"
)
VOCAB = re.compile(
    r"\b(CQRS|Event[\s\-]?Sourc(?:e|ing)|Domain[\s\-]?Driven|Aggregate\s?Root"
    r"|Bounded\s?Context)\b",
    re.I,
)
COMMENT = re.compile(
    r"^\s*(?://|#|/\*+)\s*(?:increment|decrement|loop (?:over|through)|iterate"
    r"|returns?(?: the)?(?: result| value)?\s*$|set\s+\w+\s+to\b|getter\b"
    r"|setter\b|constructor\b|initiali[sz]e\b|instantiate\b|create (?:a |an |the )"
    r"|declare\b|define\b|assign\b|end (?:of|for)\b|begin\b|start (?:of|the))",
    re.I,
)
_CMT_MARKER = re.compile(r"^\s*(?://+|#+|/\*+|\*+)\s*")
SOURCE = re.compile(
    r"\.(?:ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|kts|cs|cpp|cc|cxx|c|h|hpp|rb"
    r"|php|swift|scala|m|mm|sh|ps1|lua|dart|ex|exs|vue|svelte)$"
)
CHECKLIST_LINES = 40

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


def lang_of(rel):
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
    if ext in ("ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte"):
        return "js"
    return "other"


def git(root, *args):
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return p.stdout if p.returncode == 0 else ""


def read_whole(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="ignore") as fh:
            return [line.rstrip("\n") for line in fh][:4000]
    except OSError:
        return []


def added_lines(root, base, rel, is_git, audit):
    if is_git and not audit:
        diff = git(root, "diff", base, "--", rel) or ""
        added = [ln[1:] for ln in diff.splitlines()
                 if ln.startswith("+") and not ln.startswith("+++")]
        if added:
            return added
        if git(root, "ls-files", "--error-unmatch", "--", rel):
            return []
    return read_whole(root, rel)


def _uniq(items, limit=10):
    seen, out = set(), []
    for it in items:
        if it not in seen:
            seen.add(it)
            out.append(it)
        if len(out) >= limit:
            break
    return out


def is_redundant_comment(line):
    if not COMMENT.search(line):
        return False
    body = re.sub(r"\*/\s*$", "", _CMT_MARKER.sub("", line)).strip()
    return len(body.split()) <= 6


def scan_lines(rel, lines, audit):
    if not lines:
        return None
    base_name = os.path.basename(rel)
    deps, abstractions, comments = [], [], []
    check_deps = (not audit) and bool(MANIFEST.search(base_name))
    for ln in lines:
        if check_deps and DEP.search(ln):
            deps.append(ln.strip()[:100])
        m = ABSTRACTION.search(ln)
        if m:
            abstractions.append(m.group(1))
        else:
            v = VOCAB.search(ln)
            if v:
                abstractions.append(v.group(1))
        if is_redundant_comment(ln):
            comments.append(ln.strip()[:100])
    deps, abstractions, comments = _uniq(deps), _uniq(abstractions), _uniq(comments)
    added_count = sum(1 for ln in lines if ln.strip())
    substantial = (not audit) and bool(SOURCE.search(rel)) and added_count >= CHECKLIST_LINES
    if not (deps or abstractions or comments or substantial):
        return None
    return {"file": rel, "dependencies": deps, "abstractions": abstractions,
            "redundant_comments": comments, "added_lines": added_count,
            "substantial": substantial}


# ---- body capture + hashing ---------------------------------------------
def _indent(s):
    return len(s) - len(s.lstrip())


def capture_body(lines, start_idx, lang):
    if lang == "py":
        base = _indent(lines[start_idx])
        out = []
        for ln in lines[start_idx + 1:start_idx + 81]:
            if ln.strip() and _indent(ln) <= base:
                break
            out.append(ln)
        return "\n".join(out)
    if lang == "ruby":
        base = _indent(lines[start_idx])
        out = []
        for ln in lines[start_idx + 1:start_idx + 81]:
            if ln.strip() == "end" and _indent(ln) <= base:
                break
            out.append(ln)
        return "\n".join(out)
    # brace languages
    sig = lines[start_idx]
    arrow = sig.find("=>")
    if arrow >= 0 and sig.find("{", arrow) < 0:
        return sig[arrow + 2:].split(";")[0]
    brace_line = -1
    for k in range(start_idx, min(start_idx + 6, len(lines))):
        if "{" in lines[k]:
            brace_line = k
            break
        if ";" in lines[k] and "=>" not in lines[k]:
            return ""
    if brace_line < 0:
        return ""
    depth, started, out = 0, False, []
    for ln in lines[brace_line:brace_line + 81]:
        for ch in ln:
            if ch == "{":
                depth += 1
                if depth == 1:
                    started = True
                    continue
            elif ch == "}":
                depth -= 1
                if depth == 0 and started:
                    return "".join(out)
            if started:
                out.append(ch)
        if started:
            out.append("\n")
    return "".join(out)


def normalize_body(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r"#[^\n]*", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def structural_body(text):
    """Mask identifiers + literals; keep keywords/operators. Two bodies with the
    same control-flow shape but drifted names/values hash equal => near-duplicate."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r'"(?:[^"\\]|\\.)*"', "L", text)
    text = re.sub(r"'(?:[^'\\]|\\.)*'", "L", text)
    text = re.sub(r"`(?:[^`\\]|\\.)*`", "L", text)
    text = re.sub(r"\b\d[\w.]*\b", "N", text)
    text = ID.sub(lambda m: m.group(0) if m.group(0) in KEYWORDS else "I", text)
    return re.sub(r"\s+", "", text)


def _md5(s):
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def collect_defs(rel, lines):
    lang = lang_of(rel)
    decls = FUNC_PATTERNS.get(lang)
    if not decls:
        return []
    defs = []
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
        raw = capture_body(lines, i, lang)
        nb = normalize_body(raw)
        sb = structural_body(raw)
        exported = bool(re.search(r"\b(?:export|public|pub)\b", ln)) or "module.exports" in ln or "exports." in ln
        defs.append({
            "name": name, "file": rel, "line": i + 1, "exported": exported,
            "exact": _md5(nb) if len(nb) >= 12 else None,
            "struct": _md5(sb) if len(sb) >= 20 else None,  # skip trivial one-liners (return I;)
            "body_lines": raw.count("\n") + 1 if raw.strip() else 1,
        })
    return defs


def collect_types(rel, lines):
    if lang_of(rel) != "js":
        return []
    out = []
    for i, ln in enumerate(lines):
        m = TYPE_DECL.search(ln)
        if m:
            out.append({"name": m.group(1), "file": rel})
    return out


def analyze_duplication(defs, types, idfreq):
    by_name, by_exact, by_struct = defaultdict(list), defaultdict(list), defaultdict(list)
    name_def_counts = Counter()
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
            name_clones.append({"name": name, "count": len(ds), "files": files})
    name_clones.sort(key=lambda x: -x["count"])

    body_clones = []
    for ds in by_exact.values():
        names = sorted({d["name"] for d in ds})
        files = sorted({d["file"] for d in ds})
        if len(ds) >= 2 and (len(files) >= 2 or len(names) >= 2):
            body_clones.append({"names": names, "files": files, "count": len(ds)})
    body_clones.sort(key=lambda x: -x["count"])

    near_clones = []
    for ds in by_struct.values():
        exacts = {d["exact"] for d in ds if d["exact"]}
        if len(ds) >= 2 and len(exacts) >= 2:  # same shape, genuinely different bodies
            names = sorted({d["name"] for d in ds})
            files = sorted({d["file"] for d in ds})
            near_clones.append({"names": names, "files": files, "count": len(ds)})
    near_clones.sort(key=lambda x: -x["count"])

    single_use, seen_su = [], set()
    for d in defs:
        name = d["name"]
        if name in seen_su or name.lower() in COMMON_NAMES:
            continue
        small = d["body_lines"] <= 3
        util_ish = bool(MICRO_PREFIX.search(name)) or name.lower() in FINGERPRINTS
        if not (small or util_ish):
            continue
        # Export-aware: exported defs may be public API / framework entry points,
        # so we can't call them dead. Only judge what's internal to the repo.
        if d.get("exported"):
            continue
        refs = idfreq.get(name, 0) - name_def_counts[name]
        if refs == 0:
            seen_su.add(name)
            single_use.append({"name": name, "file": d["file"], "kind": "dead"})
        elif refs == 1 and util_ish:
            seen_su.add(name)
            single_use.append({"name": name, "file": d["file"], "kind": "inline"})

    fp = defaultdict(int)
    for d in defs:
        if d["name"].lower() in FINGERPRINTS:
            fp[d["name"]] += 1
    micro = sum(1 for d in defs if MICRO_PREFIX.search(d["name"]) and d["body_lines"] <= 3)

    type_files = defaultdict(set)
    for t in types:
        type_files[t["name"]].add(t["file"])
    type_clones = [{"name": n, "files": sorted(fs)} for n, fs in type_files.items()
                   if len(fs) >= 2 and n.lower() not in COMMON_TYPES]

    return {"name_clones": name_clones, "body_clones": body_clones,
            "near_clones": near_clones, "single_use": single_use,
            "type_clones": type_clones, "fingerprints": dict(sorted(fp.items(), key=lambda x: -x[1])),
            "micro_count": micro, "total_defs": len(defs)}


def target_files(root, base, paths, is_git, all_mode):
    if paths:
        return [p.replace("\\", "/") for p in paths]
    if not is_git:
        return []
    if all_mode:
        tracked = (git(root, "ls-files") or "").splitlines()
        return [f.strip() for f in tracked if f.strip() and SOURCE.search(f.strip())][:6000]
    names = (git(root, "diff", "--name-only", base) or "").splitlines()
    untracked = (git(root, "ls-files", "--others", "--exclude-standard") or "").splitlines()
    seen, out = set(), []
    for f in names + untracked:
        f = f.strip()
        if f and f not in seen:
            seen.add(f)
            out.append(f)
    return out


def _print_duplication(dup):
    nc, bc, near, su = dup["name_clones"], dup["body_clones"], dup["near_clones"], dup["single_use"]
    tc, fp = dup["type_clones"], dup["fingerprints"]
    if not (nc or bc or near or su or tc or fp or dup["micro_count"]):
        return False
    print("DUPLICATION (whole-codebase - the isRecord-class slop):")
    if nc:
        print("  Clone proliferation - same function name in multiple files:")
        for c in nc[:15]:
            print(f"    {c['name']:<22} x{c['count']:<3} {', '.join(c['files'][:6])}")
    if bc:
        print("  Knowledge duplication - identical body, consolidate to ONE (DRY):")
        for c in bc[:15]:
            print(f"    [{'/'.join(c['names'][:4])}] x{c['count']} across {', '.join(c['files'][:5])}")
    if near:
        print("  Semantic fragmentation - near-identical bodies (drifted clones):")
        for c in near[:12]:
            print(f"    [{'/'.join(c['names'][:4])}] x{c['count']} across {', '.join(c['files'][:5])}")
    if su:
        print("  Semantic density collapse - dead / single-use helpers:")
        for c in su[:15]:
            tag = "unused & not exported -> delete" if c["kind"] == "dead" else "used once -> inline"
            print(f"    {c['name']:<24} {tag:<32} {c['file']}")
    if tc:
        print("  Duplicate type/interface names:")
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


def main():
    ap = argparse.ArgumentParser(description="Static AI-slop signal scanner (reports only).")
    ap.add_argument("paths", nargs="*", help="specific files to audit (default: the git diff)")
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--base", default="HEAD", help="git ref to diff against in diff scope")
    ap.add_argument("--all", action="store_true", help="audit ALL tracked source files + duplication")
    ap.add_argument("--gate", action="store_true", help="exit non-zero if any slop is found (for loops/CI)")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    is_git = bool(git(root, "rev-parse", "--git-dir"))
    audit = args.all or bool(args.paths)
    files = target_files(root, args.base, args.paths, is_git, args.all)

    file_lines = {f: added_lines(root, args.base, f, is_git, audit) for f in files}
    results = [r for r in (scan_lines(f, ls, audit) for f, ls in file_lines.items()) if r]

    dup = None
    if audit:
        idfreq = Counter()
        defs, types = [], []
        for f, ls in file_lines.items():
            for ln in ls:
                idfreq.update(ID.findall(ln))
            defs.extend(collect_defs(f, ls))
            types.extend(collect_types(f, ls))
        dup = analyze_duplication(defs, types, idfreq)
    mode = "audit" if audit else "diff"

    totals = {
        "dependencies": sum(len(r["dependencies"]) for r in results),
        "abstractions": sum(len(r["abstractions"]) for r in results),
        "redundant_comments": sum(len(r["redundant_comments"]) for r in results),
        "files": len(results),
    }

    if args.format == "json":
        print(json.dumps({"mode": mode, "base": args.base, "git": is_git,
                          "totals": totals, "files": results, "duplication": dup}, indent=2))
        return 0

    if not is_git and not args.paths:
        print("anti-slop scan: not a git repo and no paths given.")
        print("Audit files: `scan_slop.py src/foo.ts`, or run inside a git repo with --all.")
        return 0

    has_dup = bool(dup and _print_duplication(dup))

    if results:
        print(f"anti-slop scan ({mode}) - {totals['files']} file(s) with per-file signals\n")
        for r in results:
            print(r["file"])
            for d in r["dependencies"]:
                print(f"  new dependency       : {d}")
            for a in r["abstractions"]:
                print(f"  premature abstraction: {a}")
            for c in r["redundant_comments"]:
                print(f"  redundant comment    : {c}")
            if r["substantial"] and not (r["dependencies"] or r["abstractions"] or r["redundant_comments"]):
                print(f"  +{r['added_lines']} added lines (>= {CHECKLIST_LINES}: run the checklist)")
            print()

    if not results and not has_dup:
        if audit:
            print(f"anti-slop scan ({mode}) - no static slop patterns across {len(files)} file(s).")
            print("Clean of the deterministic signals. Semantic slop still needs a model pass:")
            print("invoke the anti-slop skill for edge cases / superficial tests / cargo-cult.")
        else:
            print(f"anti-slop scan (diff) - nothing changed vs {args.base} (clean working tree).")
            print("Diff scope only vets a change in progress. To review existing code:")
            print("  scan_slop.py --all          (whole codebase + duplication)")
            print("  scan_slop.py path/to/file   (specific files)")
        if args.gate:
            print("GATE: PASS (no slop)")
        return 0

    print(f"SUMMARY ({mode}): {totals['dependencies']} dep, {totals['abstractions']} abstraction, "
          f"{totals['redundant_comments']} redundant-comment", end="")
    if dup:
        print(f"; {len(dup['name_clones'])} name-clone, {len(dup['body_clones'])} exact-dup, "
              f"{len(dup['near_clones'])} near-dup, {len(dup['single_use'])} single-use", end="")
    print(".")
    print("Fix every signal above, then walk the full taxonomy in SKILL.md and re-scan (expect clean).")
    if args.gate:
        print("GATE: FAIL (slop found)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
