#!/usr/bin/env bash
# intent-precompile.sh - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# THE fix for ".scope.json isn't updating": fires right after the user hits
# send, BEFORE the agent's first token, with the prompt in the payload directly.
# Writes the prompt as .scope.json's `intent` field. If .scope.json already
# exists, PRESERVES files[] and acceptance (cross-prompt continuity — the
# blast radius accumulates across turns). If it doesn't exist, creates it.
#
# This is the hook that makes .scope.json track the conversation without
# relying on the agent to write it. The agent refines intent/acceptance as
# its first action; the hook just ensures the contract EXISTS and reflects
# the current prompt. scope-refresh (afterFileEdit) then keeps files[] in
# sync as edits happen.
#
# Skips hook-generated auto-submits (FINAL REVIEW / SCOPE REMINDER / etc.) —
# those are review boilerplate, not user prompts. Never blocks; writes files
# as a side effect and exits 0. No repo root → silent (no ghost files in $HOME).
# Disable: HOOKS_ENFORCE=0 or INTENT_PRECOMPILE_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_PRECOMPILE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

prompt="$(json_get "$input" prompt)"
prompt="$(printf '%s' "$prompt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$prompt" ] || exit 0

# Skip hook-generated auto-submits (review followups the harness resubmits).
case "$prompt" in
    "FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*|"INTENT REFINEMENT REQUIRED"*|"SCOPE REMINDER"*) exit 0 ;;
esac

root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
default_acceptance='Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

if [ -f "$scope_path" ]; then
    # Existing contract: update intent, preserve files[] and acceptance.
    scope_raw="$(cat "$scope_path" 2>/dev/null)"
    if have_jq; then
        new_raw="$(printf '%s' "$scope_raw" | jq --arg p "$prompt" '.intent = $p' 2>/dev/null)"
    elif have_py; then
        new_raw="$(P="$prompt" python3 -c '
import json, os, sys
try:
    o = json.load(sys.stdin)
    o["intent"] = os.environ["P"]
    print(json.dumps(o, indent=2, ensure_ascii=False))
except Exception:
    pass' <<< "$scope_raw" 2>/dev/null)"
    else
        exit 0
    fi
    [ -n "$new_raw" ] && printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
else
    # Fresh contract.
    if have_jq; then
        jq -cna \
            --arg p "$prompt" \
            --arg a "$default_acceptance" \
            '{intent: $p, files: [], acceptance: $a}' > "$scope_path" 2>/dev/null
    elif have_py; then
        P="$prompt" A="$default_acceptance" python3 -c '
import json, os
print(json.dumps({
    "intent": os.environ["P"],
    "files": [],
    "acceptance": os.environ["A"],
}, indent=2, ensure_ascii=False))' > "$scope_path" 2>/dev/null
    fi
fi

exit 0
