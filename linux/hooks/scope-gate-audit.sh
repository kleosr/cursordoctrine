#!/usr/bin/env bash
# scope-gate-audit.sh - afterFileEdit "declared scope" advisory (Cursor, Linux).
#
# Compuerta 1 of the anti-slop system: the declared-scope gate. When the agent
# writes a .scope.json contract (intent + files[] + acceptance), this hook
# checks every edited file against it. Editing OUTSIDE the declared set is the
# textbook scope-creep / gold-plating signal. Advisory only (no preToolUse for
# file edits on Cursor); the violation is flagged on the next turn.
#
# Opt-in: if .scope.json does not exist in the repo root, this hook is silent.
# No contract = no gate (fallback to declared-editing ladder + final-review).
#
# Mechanism: resolve edited file -> repo-relative, run scope_match.py against
# .scope.json's files[], append advisory to feedback-<cid>.txt on violation.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0.
# Disable: HOOKS_ENFORCE=0  or  SCOPE_GATE_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_GATE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# audit root: project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
root=""
while IFS= read -r cand; do
    [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
[ -n "$root" ] || root="${CURSOR_PROJECT_DIR:-$HOME}"
root="${root%/}"

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

# --- opt-in gate: no .scope.json = no gate ---------------------------------
scope_file="$root/.scope.json"
[ -f "$scope_file" ] || exit 0

# --- resolve Python + run scope_match.py ---------------------------------
py=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then py="$c"; break; fi
done
[ -n "$py" ] || exit 0   # no Python -> fail open

matcher="$HOME/.cursor/skills/anti-slop/scripts/scope_match.py"
[ -f "$matcher" ] || exit 0   # skill not installed -> silent

mout="$("$py" "$matcher" --path "$rel" --patterns-file "$scope_file" 2>/dev/null)"
[ -n "$mout" ] || exit 0

# --- parse the JSON result (reuse the Python we already resolved) ----------
parse_result() {
    "$py" - "$@" <<'PYEOF' 2>/dev/null
import json, sys
try:
    p = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
if p.get("skipped"):
    sys.exit(2)   # no valid contract -> fail-open
if p.get("in_scope"):
    sys.exit(3)   # in scope -> clean
allow_growth = "1" if p.get("allow_growth") else "0"
intent = p.get("intent", "")
acceptance = p.get("acceptance", "")
print(f"__AG__{allow_growth}")
print(f"__INTENT__{intent}")
print(f"__ACCEPT__{acceptance}")
sys.exit(0)
PYEOF
}

parsed="$(printf '%s' "$mout" | parse_result)"
rc=$?
[ "$rc" -eq 0 ] || exit 0   # 2=skipped, 3=in-scope, 1=parse-fail -> all silent

allow_growth="$(printf '%s\n' "$parsed" | grep '__AG__' | sed 's/__AG__//')"
intent="$(printf '%s\n' "$parsed" | grep '__INTENT__' | sed 's/__INTENT__//')"
acceptance="$(printf '%s\n' "$parsed" | grep '__ACCEPT__' | sed 's/__ACCEPT__//')"

# Read declared files for the message (best-effort)
declared_files="$(printf '%s' "$scope_file" | "$py" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(', '.join(d.get('files', [])))
except Exception:
    pass
" "$scope_file" 2>/dev/null)"

# --- compose advisory ------------------------------------------------------
# acceptance line: only quote it when the agent declared one. A blank acceptance
# means the Anchor Set was incomplete - surface that gap, since the whole point
# of the pre-compile phase is to name the deterministic success check.
if [ -n "$acceptance" ]; then
    acceptance_line="$acceptance"
else
    acceptance_line="(not declared - your Anchor Set is missing the EXITO/acceptance field)"
fi

if [ "$allow_growth" = "1" ]; then
    summary="Scope note - $rel is new vs your declared scope (growth allowed)"
    body="  You touched a file outside your initial declared set. Since allow_growth is
  true, this is not a violation, but justify it: add $rel to .scope.json or
  explain why the scope grew.

  Your success contract (acceptance): $acceptance_line
  Does growing into $rel still serve that?"
else
    summary="[SCOPE VIOLATION] $rel is NOT in your declared scope"
    body="  Your contract (.scope.json):
    intent: $intent
    files: $declared_files
    acceptance: $acceptance_line

  You declared these files and touched one outside the set. Either:
    1. Add $rel to .scope.json with a one-line justification, OR
    2. Revert the change - it is out of scope for the declared intent.

  Declared-editing: declare BEFORE you expand. Don't sneak edits past the gate."
fi

msg="${summary}

${body}

(Advisory; disable: SCOPE_GATE_ENFORCE=0)"

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
