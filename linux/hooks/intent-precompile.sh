#!/usr/bin/env bash
# intent-precompile.sh - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# Fires right after the user hits send, BEFORE the agent's first token.
# Hook-owned field: `prompt` (verbatim latest user message).
# Agent-owned fields: `intent` (Step 0 restatement), initial `files[]` blast
# radius, sharpened `acceptance`.
#
# Continuation: update `prompt` only; preserve intent, files[], acceptance.
# New task (prefix /new, "new task:", "new task —"): reset intent, files[],
# acceptance to defaults; agent must restate.
#
# scope-refresh (afterFileEdit) appends edited paths to files[].
# Skips hook-generated auto-submits. Never blocks. Disable:
# HOOKS_ENFORCE=0 or INTENT_PRECOMPILE_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_PRECOMPILE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

prompt="$(json_get "$input" prompt)"
prompt="$(printf '%s' "$prompt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$prompt" ] || exit 0

case "$prompt" in
    "FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*|"INTENT REFINEMENT REQUIRED"*|"SCOPE REMINDER"*|"VERIFY MILESTONE"*) exit 0 ;;
esac

root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
default_acceptance='Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

is_new_task() {
    local p lower
    p="$(printf '%s' "$1" | sed 's/^[[:space:]]*//')"
    lower="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        /new*) return 0 ;;
        new\ task:*) return 0 ;;
        new\ task\ —*|new\ task\ -*) return 0 ;;
    esac
    return 1
}

if [ -f "$scope_path" ]; then
    scope_raw="$(cat "$scope_path" 2>/dev/null)"
    if is_new_task "$prompt"; then
        if have_jq; then
            new_raw="$(jq -nc \
                --arg p "$prompt" \
                --arg a "$default_acceptance" \
                '{prompt: $p, intent: "", decomposition: [], verifications: [], files: [], acceptance: $a}' 2>/dev/null)"
        elif have_py; then
            new_raw="$(P="$prompt" A="$default_acceptance" python3 -c '
import json, os
print(json.dumps({
    "prompt": os.environ["P"],
    "intent": "",
    "decomposition": [],
    "verifications": [],
    "files": [],
    "acceptance": os.environ["A"],
}, indent=2, ensure_ascii=False))' 2>/dev/null)"
        else
            exit 0
        fi
    elif have_jq; then
        new_raw="$(printf '%s' "$scope_raw" | jq --arg p "$prompt" '
            .prompt = $p
            | if (.intent | type) != "string" then .intent = "" else . end
            | del(.trace, .allow_growth)
            | with_entries(select(.key | startswith("_") | not))
        ' 2>/dev/null)"
    elif have_py; then
        new_raw="$(P="$prompt" python3 -c '
import json, os, sys
try:
    o = json.load(sys.stdin)
    o["prompt"] = os.environ["P"]
    if not isinstance(o.get("intent"), str):
        o["intent"] = ""
    for k in list(o.keys()):
        if k.startswith("_") or k in ("trace", "allow_growth"):
            del o[k]
    print(json.dumps(o, indent=2, ensure_ascii=False))
except Exception:
    pass' <<< "$scope_raw" 2>/dev/null)"
    else
        exit 0
    fi
    [ -n "$new_raw" ] && printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
else
    if have_jq; then
        jq -nc \
            --arg p "$prompt" \
            --arg a "$default_acceptance" \
            '{prompt: $p, intent: "", decomposition: [], verifications: [], files: [], acceptance: $a}' > "$scope_path" 2>/dev/null
    elif have_py; then
        P="$prompt" A="$default_acceptance" python3 -c '
import json, os
print(json.dumps({
    "prompt": os.environ["P"],
    "intent": "",
    "decomposition": [],
    "verifications": [],
    "files": [],
    "acceptance": os.environ["A"],
}, indent=2, ensure_ascii=False))' > "$scope_path" 2>/dev/null
    fi
fi

exit 0
