#!/usr/bin/env python3
"""scope_match.py - declared-scope glob matcher (shared helper).

One job: given a repo-relative path and a list of declared-scope patterns
(from .scope.json `files`), return whether the path is in scope. Shared
between the per-edit scope-gate-audit hook (afterFileEdit) and final-review's
declared-scope check (Step C), so the two never disagree on what counts as
"in scope". It also surfaces the contract's `intent` and `acceptance` fields
so the calling hook can quote them back to the agent.

.scope.json schema (intent + files[] + acceptance + allow_growth):
  {
    "intent":       "one operational sentence of objective",
    "files":        [ "repo-relative globs", ... ],
    "acceptance":   "the deterministic check that decides success",
    "allow_growth": false
  }

Pattern support:
  - exact path:   src/components/LoginButton.tsx
  - glob *:       src/styles/*.css           (single segment, no /)
  - glob **:      src/**/test_*.py           (recursive across dirs)
  - bare dir:     src/components             (matches everything under it)

Stdlib only; Python 3.9+. REPORTS only - never edits.

CLI:
  scope_match.py --path src/auth/session.ts --patterns-file .scope.json
  -> prints JSON {"in_scope": false, "matched_by": null, "acceptance": "..."}
     and exits 0
  -> if .scope.json is missing or unparseable, prints {"in_scope": true,
     "skipped": "no .scope.json"} (fail-open: no contract = no gate)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Sentinel chars for anchoring; built once, used in the regex below.
_ANCHOR_START = "^"
_ANCHOR_END = "$"


def _pattern_to_regex(pattern: str) -> re.Pattern:
    """Convert a glob pattern to a compiled regex matching the WHOLE path.

    Standard glob semantics (NOT fnmatch's):
      **  matches any chars INCLUDING / (recursive)
      *   matches any chars EXCEPT / (single segment)
      ?   matches a single char EXCEPT /
      A bare directory pattern (basename has no dot, e.g. 'src/components')
      matches the dir AND everything beneath it.
    """
    bare = pattern.rstrip("/")
    base = os.path.basename(bare)
    is_dir = ("." not in base)

    out: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*" and i + 1 < len(pattern) and pattern[i + 1] == "*":
            out.append(".*")           # ** crosses /
            i += 2
        elif c == "*":
            out.append("[^/]*")        # * stays within a segment
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    body = "".join(out)

    if is_dir:
        body = body + "(/.*)?"

    return re.compile(_ANCHOR_START + body + _ANCHOR_END)


def in_scope(path: str, patterns: list) -> tuple:
    """Return (matched_bool, matched_by_pattern_or_None)."""
    norm = path.replace("\\", "/").lstrip("/")
    for p in patterns:
        p = p.strip().replace("\\", "/")
        if not p:
            continue
        if _pattern_to_regex(p).match(norm):
            return True, p
    return False, None


def load_scope(scope_path: str):
    """Load and validate .scope.json. Returns the dict, or None if missing/
    unparseable (fail-open: no contract = no gate fires)."""
    if not os.path.isfile(scope_path):
        return None
    try:
        with open(scope_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return None
        if not isinstance(data.get("files", []), list):
            return None
        return data
    except (json.JSONDecodeError, OSError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Declared-scope glob matcher (shared helper).")
    ap.add_argument("--path", required=True,
                    help="repo-relative path to check")
    ap.add_argument("--patterns-file",
                    help="path to .scope.json (default: .scope.json in cwd)")
    ap.add_argument("--patterns",
                    help="comma-separated patterns (overrides --patterns-file)")
    args = ap.parse_args()

    if args.patterns:
        patterns = [p.strip() for p in args.patterns.split(",") if p.strip()]
        matched, by = in_scope(args.path, patterns)
        result = {"in_scope": matched, "matched_by": by}
    else:
        scope_path = args.patterns_file or os.path.join(os.getcwd(), ".scope.json")
        scope = load_scope(scope_path)
        if scope is None:
            print(json.dumps({"in_scope": True, "skipped": "no valid .scope.json"}))
            return 0
        patterns = [str(f) for f in scope.get("files", [])]
        matched, by = in_scope(args.path, patterns)
        result = {
            "in_scope": matched,
            "matched_by": by,
            "allow_growth": bool(scope.get("allow_growth", False)),
            "intent": scope.get("intent", ""),
            "acceptance": scope.get("acceptance", ""),
        }

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
