#!/usr/bin/env bash
# intent-anchor.sh - postToolUse: one-shot nudge to fill the .scope.json contract.
#
# The .scope.json contract divides labor: hook owns prompt + files[] +
# verifications[]; agent owns intent (Step 0 restatement) + acceptance (real
# done-check) + decomposition. When the agent skips its half — leaves intent
# empty and/or acceptance at the default seed — the contract is degraded:
# final-review's intent trace falls back to the raw prompt, and the acceptance
# bar shown is generic rather than task-specific.
#
# This hook fires AT MOST ONCE per conversation_id, on the first postToolUse
# where .scope.json exists and either field is still empty/default. It emits
# an INTENT ANCHOR reminder as additional_context so the agent fills the
# contract before going further. The hook never writes intent or acceptance;
# it just surfaces the gap.
#
# The per-cid flag (intent-anchored-<cid>.flag) is armed BEFORE emitting, so a
# crash can't re-fire and the agent won't see the nudge twice. If intent AND
# acceptance are both already filled/customized when the hook first runs, the
# flag is armed silently (no emission) so we never bug this cid again.
#
# Disable: HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_ANCHOR_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

cid="$(safe_conversation_id "$input")"
root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

# One-shot per cid. Once the flag exists we never fire again for this convo.
pending_dir="$HOME/.cursor/.hooks-pending"
flag="$pending_dir/intent-anchored-$cid.flag"
[ -f "$flag" ] && exit 0

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || exit 0

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || exit 0

# Need python3 OR jq for the field reads. Without either, fail open silently.
if ! have_jq && ! have_py; then exit 0; fi

default_acceptance='Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

if have_jq; then
    intent="$(printf '%s' "$scope_raw" | jq -r '.intent // empty' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | jq -r '.acceptance // empty' 2>/dev/null)"
    prompt="$(printf '%s' "$scope_raw" | jq -r '.prompt // empty' 2>/dev/null)"
elif have_py; then
    intent="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("intent") or "")
except Exception: pass' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("acceptance") or "")
except Exception: pass' 2>/dev/null)"
    prompt="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("prompt") or "")
except Exception: pass' 2>/dev/null)"
fi

intent_empty=false
acceptance_default=false
[ -z "$intent" ] && intent_empty=true
[ "$acceptance" = "$default_acceptance" ] && acceptance_default=true

# Arm the flag BEFORE any emission so a crash can't re-fire. This also covers
# the "both already filled" case: arm silently and exit.
mkdir -p "$pending_dir" 2>/dev/null
touch "$flag" 2>/dev/null

if [ "$intent_empty" = "false" ] && [ "$acceptance_default" = "false" ]; then
    exit 0
fi

msg='INTENT ANCHOR: the .scope.json contract is incomplete. The harness can only re-inject what you write — fill the agent-owned fields now:'
if [ "$intent_empty" = "true" ]; then
    msg="$msg
  - intent: empty. Write your one-line Step 0 restatement of the task (NOT the verbatim prompt)."
else
    msg="$msg
  - intent: OK"
fi
if [ "$acceptance_default" = "true" ]; then
    msg="$msg
  - acceptance: still the default seed. Sharpen it to this task's real done-check (e.g. specific test command, specific behavior that must hold)."
else
    msg="$msg
  - acceptance: OK"
fi
msg="$msg

Current prompt: $prompt
Next edit won't re-trigger this nudge — the harness arms the flag once per session."

emit_json additional_context "$msg"
exit 0
