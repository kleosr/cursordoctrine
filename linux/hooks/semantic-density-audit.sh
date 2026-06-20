#!/usr/bin/env bash
# semantic-density-audit.sh - afterFileEdit "semantic opacity" advisory (Cursor, Linux).
#
# Guards the naming layer the other audit hooks do not see. anti-slop-audit
# watches generated-code PATTERNS; this hook watches whether the identifiers
# the agent JUST introduced actually communicate intent. DataManager,
# process(), utils.ts, CoreEngine - names that exist but say nothing.
#
# Mechanism: extract ADDED lines from `git diff HEAD -- <rel>` (with the
# untracked-file fallback anti-slop-audit uses), pipe them to density_scan.py
# (a thin wrapper over the shared low_density module), read back one JSON
# object of findings, append a short advisory to the shared pending-feedback
# file. One denylist, shared with scan_slop.py's semantic_density bucket -
# zero drift between the per-edit advisory and the audit-of-record.
#
# FAIL findings (DataManager / Utils / placeholder names) always fire. WARN
# findings (defensible DDD with a domain noun - PostgresUserRepository) only
# fire when at least one FAIL is also present, so the hook stays quiet on
# legitimate code and loud on the real slop.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0.
# Disable: HOOKS_ENFORCE=0  or  SEMANTIC_DENSITY_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SEMANTIC_DENSITY_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# audit root: shared resolver (cwd -> workspace_roots -> CURSOR_PROJECT_DIR; NO
# $HOME fallback - no ghost files, no auditing the wrong root).
root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

# edited file -> repo-relative path
fp=""
for k in file_path path filename absolute_path abs_path; do
    fp="$(json_get "$input" "$k")"
    [ -n "$fp" ] && break
done
[ -n "$fp" ] || exit 0
rel="$fp"
case "$rel" in "$root"/*) rel="${rel#"$root"/}" ;; esac
if is_cursor_config_path "$fp" || is_cursor_config_path "$rel"; then exit 0; fi

# git repo?
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# --- collect ADDED lines for this file (working tree vs HEAD) --------------
added="$(git -C "$root" diff HEAD -- "$rel" 2>/dev/null |
    grep -E '^\+' | grep -vE '^\+\+\+' | cut -c2- | head -n 1500)"
if [ -z "$added" ]; then
    # untracked / brand-new file: whole file is "added"
    if ! git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        [ -f "$root/$rel" ] && added="$(head -n 1500 "$root/$rel")"
    fi
fi
[ -n "$added" ] || exit 0

# --- resolve Python + run density_scan.py ---------------------------------
# Linux ships python3; fall back to python for older distros.
py=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then py="$c"; break; fi
done
[ -n "$py" ] || exit 0   # no Python -> fail open, scanner unavailable

scanner="$HOME/.cursor/skills/anti-slop/scripts/density_scan.py"
[ -f "$scanner" ] || exit 0   # skill not installed -> silent

# Pipe added lines to the scanner, read JSON back.
mout="$(printf '%s\n' "$added" | "$py" "$scanner" --rel "$rel" 2>/dev/null)"
[ -n "$mout" ] || exit 0

# --- parse JSON findings with python (the hook already requires python) ----
# jq would be ideal but the installer notes python3 as the fallback; reuse it.
parse_json() {
    "$py" - "$@" <<'PYEOF' 2>/dev/null
import json, sys
try:
    p = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
fails = [f for f in p.get("findings", []) if f.get("severity") == "fail"]
warns = [f for f in p.get("findings", []) if f.get("severity") == "warn"]
if not fails and not warns:
    sys.exit(2)
# WARNs only fire alongside a FAIL (defensible DDD stays quiet on clean code).
flagged = fails + (warns if fails else [])
lines = []
for f in (flagged)[:12]:
    tag = f.get("severity", "").upper()
    ln = f.get("line", 0)
    where = f"line {ln}" if ln and ln > 0 else "file name"
    reason = "; ".join(f.get("reasons", []))
    if len(reason) > 110:
        reason = reason[:107] + "..."
    lines.append(f"  [{tag}] {f.get('kind','?')} '{f.get('name','?')}' ({where}): {reason}")
print("\n".join(lines))
print(f"__COUNTS__{len(fails)}__{len(warns)}")
PYEOF
}

parsed="$(printf '%s' "$mout" | parse_json)"
rc=$?
[ "$rc" -eq 0 ] || exit 0   # parse failed or no findings -> silent

# Split the parsed output: findings lines + the __COUNTS__N__N sentinel.
counts_line="$(printf '%s\n' "$parsed" | grep '__COUNTS__' | tail -1)"
findings_block="$(printf '%s\n' "$parsed" | grep -v '__COUNTS__')"
fail_n="$(printf '%s' "$counts_line" | sed -E 's/.*__COUNTS__([0-9]+)__.*/\1/')"
warn_n="$(printf '%s' "$counts_line" | sed -E 's/.*__[0-9]+__([0-9]+)/\1/')"

# --- compose advisory ------------------------------------------------------
summary="Semantic-density audit - $rel - ${fail_n} FAIL, ${warn_n} WARN"

advice='  High-density names are predictable from the name alone (InvoiceEmailSender,
  PostgresUserRepository, GenerateMonthlyReport). Low-density names name a
  category, not a thing (Manager, Utils, process, handleThing). Rename so the
  identifier states its concrete responsibility. WARNs with a domain noun are
  defensible DDD and can be left if intentional.'

msg="${summary}

${findings_block}

${advice}

(Advisory; disable: SEMANTIC_DENSITY_ENFORCE=0)"

# --- append to the shared pending file --------------------------------------
cid="$(safe_conversation_id "$input")"
pending="$(hooks_pending_dir)/feedback-${cid}.txt"
mkdir -p "$(dirname "$pending")" 2>/dev/null
if [ -s "$pending" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending" 2>/dev/null
fi

exit 0
