#!/usr/bin/env python3
"""density_scan.py - per-edit semantic-density hook wrapper.

The afterFileEdit hook (semantic-density-audit.{ps1,sh}) extracts the ADDED
lines for the just-edited file from `git diff HEAD` and pipes them here on
stdin. This wrapper scores them with the shared low_density module and emits
one JSON object the hook can read. One job, one contract:

    stdin:  added lines (one per line, leading '+' already stripped)
    argv:   --rel <repo-relative path of the edited file>
    stdout: {"rel": ..., "findings": [...], "count": N}
            where each finding = {name, line, kind, severity, reasons}
    exit:   0 always (advisory; the hook never blocks)

Why a separate wrapper instead of `scan_slop.py --added-json -`? scan_slop's
per-file signal loop is the right granularity for a whole-codebase audit, but
the hook needs ONE call that ingests pre-extracted added lines and returns
density findings only - no dep/abstraction/residue detection (that is
anti-slop-audit's job, already running in the same afterFileEdit slot). This
keeps the two hooks non-overlapping and the density path fast (<50ms typical).

Stdlib only; Python 3.9+. REPORTS only - never edits.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

# Resolve sibling low_density.py + scan_slop.py the same way low_density does.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

import low_density  # noqa: E402  (path set up above)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Per-edit semantic-density scorer (hook wrapper).")
    ap.add_argument("--rel", required=True,
                    help="repo-relative path of the edited file (used for "
                         "language detection and filename scoring)")
    ap.add_argument("--max-lines", type=int, default=2000,
                    help="cap on stdin lines read (runtime bound, matches the "
                         "hook's own 1500-line git cap with headroom)")
    args = ap.parse_args()

    rel = args.rel.replace("\\", "/").lstrip("/")

    # Read added lines from stdin. The hook already stripped leading '+' and
    # '+++' headers and applied its own cap; we apply a defensive second cap.
    added: list[str] = []
    try:
        for i, line in enumerate(sys.stdin):
            if i >= args.max_lines:
                break
            added.append(line.rstrip("\n"))
    except (KeyboardInterrupt, IOError):
        pass

    findings: list[dict[str, Any]] = low_density.score_identifiers(added, rel)

    payload = {
        "rel": rel,
        "findings": findings,
        "count": len(findings),
        "fail_count": sum(1 for f in findings if f.get("severity") == "fail"),
        "warn_count": sum(1 for f in findings if f.get("severity") == "warn"),
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
