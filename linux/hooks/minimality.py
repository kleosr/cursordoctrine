#!/usr/bin/env python3
r"""Minimal-edit metrics for final-review.sh (over-editing signal).

Per touched file, against git HEAD:
  rewrite-ratio     1 - token-level similarity(HEAD, worktree), 0..1. Tokens
                    are \w+ runs or single punctuation chars, so a renamed
                    identifier costs 1, not its character length — the
                    token-level Levenshtein analog from nrehiew's over-editing
                    work, with difflib as the stdlib stand-in.
  structural delta  branch/boolean/try constructs added vs HEAD — the
                    Added-Cognitive-Complexity analog. A faithful value fix
                    adds ~0 structure.

argv: <repo_root> <rel_file>...
stdout: FILE\t<rel>\t<ratio|new|bin>\t<delta> per file, then
        SUMMARY\t<worst_ratio>\t<worst_file>\t<total_delta>
Untracked files have no HEAD side: ratio reports as 'new' and is excluded
from worst_ratio; their full structure still counts toward delta (a surgical
fix that ships a new branchy file is still over-editing).

The structural keyword set spans C-likes (if/switch/case/catch/&&/||),
Python (elif/except/and/or), Ruby/Elixir (elsif/unless/rescue/when),
Kotlin (when), Rust/Scala/Python 3.10 (match), Swift (guard), PHP/Lua
(elseif). ponytail: difflib.ratio is not exact Levenshtein; the counter has
no nesting penalty and matches keywords inside strings/comments (both sides
count them, so the delta only moves when added text does) — `match`/`when`
also hit JS method calls and test mocks, acceptable for a delta.
Upgrade path = tokenize+DP Levenshtein and ast-based Cognitive Complexity
for .py. Files over 30k tokens fall back to quick_ratio, which overestimates
similarity and therefore underestimates the rewrite.
"""
import re
import subprocess
import sys
from difflib import SequenceMatcher

TOKEN = re.compile(r"\w+|[^\w\s]")
STRUCT = re.compile(
    r"\b(?:if|elif|elsif|elseif|unless|for|while|switch|case|when|match|guard"
    r"|catch|except|rescue|try|and|or)\b|&&|\|\|"
)
QUICK_RATIO_TOKEN_CEILING = 30000


def head_text(root, rel):
    proc = subprocess.run(
        ["git", "-C", root, "show", f"HEAD:{rel}"],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return proc.stdout if proc.returncode == 0 else None


def worktree_text(root, rel):
    try:
        with open(f"{root}/{rel}", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def main():
    root, rels = sys.argv[1], sys.argv[2:]
    worst_ratio, worst_file, total_delta = -1.0, "", 0
    for rel in rels:
        after = worktree_text(root, rel)
        if after is None:
            continue
        before = head_text(root, rel)
        if "\x00" in after or (before and "\x00" in before):
            print(f"FILE\t{rel}\tbin\t0")
            continue
        delta = len(STRUCT.findall(after)) - len(STRUCT.findall(before or ""))
        total_delta += delta
        if before is None:
            print(f"FILE\t{rel}\tnew\t{delta}")
            continue
        a, b = TOKEN.findall(before), TOKEN.findall(after)
        sm = SequenceMatcher(None, a, b, autojunk=False)
        similarity = sm.quick_ratio() if max(len(a), len(b)) > QUICK_RATIO_TOKEN_CEILING else sm.ratio()
        ratio = 1.0 - similarity
        if ratio > worst_ratio:
            worst_ratio, worst_file = ratio, rel
        print(f"FILE\t{rel}\t{ratio:.4f}\t{delta}")
    print(f"SUMMARY\t{worst_ratio:.4f}\t{worst_file}\t{total_delta}")


if __name__ == "__main__":
    main()
