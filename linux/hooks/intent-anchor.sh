#!/usr/bin/env bash
# intent-anchor.sh - postToolUse: persistent nudge to fill the .scope.json contract.
#
# The .scope.json contract divides labor: hook owns prompt + files[] +
# verifications[]; agent owns intent (Step 0 restatement) + acceptance (real
# done-check) + decomposition. When the agent skips its half — leaves intent
# empty and/or acceptance at the default seed — the contract is degraded:
# final-review's intent trace falls back to the raw prompt, and the acceptance
# bar shown is generic rather than task-specific.
#
# This hook re-fires whenever NEW files have been edited since the last nudge
# and the contract is still incomplete (empty intent and/or default acceptance).
# The per-cid flag stores the files[] count at last fire; if files[] hasn't
# grown, the hook stays silent (no new work to anchor against). Once intent AND
# acceptance are both filled, the hook goes silent permanently for this cid.
# This replaces the old one-shot-per-session design: a single ignored nudge
# left intent empty for the entire session. Now every new edit re-surfaces
# the gap until the agent fills it.
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

# Per-cid throttle: the flag stores "filesCount:nudgeCount". Re-fire only when
# files[] has grown since the last nudge AND we haven't exceeded the nudge cap
# (default 99999 — effectively unlimited). History: the cap was 3 (too low: a
# 10-file task went permanently silent after 3 ignored nudges and the contract
# stayed broken for the whole session), then 8 (still exhausted mid-session on
# a 30-file audit, leaving intent empty with zero further signal). A contract
# that can be emptied by an ignoring agent is worse than a noisy one, so the cap
# is now effectively unbounded. Re-nudges still only fire on NEW file edits
# (avoids spamming when nothing changes); the final-review axis 0 FAIL is the
# hard backstop at stop time. Override: INTENT_ANCHOR_NUDGE_CAP.
nudge_cap="${INTENT_ANCHOR_NUDGE_CAP:-99999}"
case "$nudge_cap" in ''|*[!0-9]*) nudge_cap=99999 ;; esac
pending_dir="$HOME/.cursor/.hooks-pending"
flag="$pending_dir/intent-anchored-$cid.flag"

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
    files_count="$(printf '%s' "$scope_raw" | jq -r '.files // [] | length' 2>/dev/null)"
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
    files_count="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("files") or []))
except Exception: print(0)' 2>/dev/null)"
fi

intent_empty=false
intent_draft=false
acceptance_default=false
[ -z "$intent" ] && intent_empty=true
case "$intent" in "[DRAFT]"*) intent_draft=true ;; esac
[ "$acceptance" = "$default_acceptance" ] && acceptance_default=true

# Read flag: "filesCount:nudgeCount".
last_count=-1
nudge_count=0
if [ -f "$flag" ]; then
    flag_data="$(cat "$flag" 2>/dev/null)"
    last_count="$(printf '%s' "$flag_data" | cut -d: -f1 | tr -dc '0-9-')"
    nudge_count="$(printf '%s' "$flag_data" | cut -d: -f2 | tr -dc '0-9')"
    [ -n "$last_count" ] || last_count=-1
    [ -n "$nudge_count" ] || nudge_count=0
fi

# Both filled → contract complete. Store count and stay silent permanently.
if [ "$intent_empty" = "false" ] && [ "$intent_draft" = "false" ] && [ "$acceptance_default" = "false" ]; then
    mkdir -p "$pending_dir" 2>/dev/null
    printf '%s:0' "${files_count:-0}" > "$flag" 2>/dev/null
    exit 0
fi

# Contract incomplete but no new files since last nudge → stay silent.
if [ "$last_count" -ge 0 ] && [ "${files_count:-0}" -le "$last_count" ]; then
    exit 0
fi

# Contract incomplete but nudge cap exceeded → stay silent.
if [ "$nudge_count" -ge "$nudge_cap" ]; then
    exit 0
fi

# Contract incomplete AND new files AND under cap → emit.
nudge_count=$((nudge_count + 1))
mkdir -p "$pending_dir" 2>/dev/null
printf '%s:%s' "${files_count:-0}" "$nudge_count" > "$flag" 2>/dev/null

msg='INTENT ANCHOR: the .scope.json contract is incomplete. The harness can only re-inject what you write — fill the agent-owned fields now:'
if [ "$intent_empty" = "true" ]; then
    msg="$msg
  - intent: empty. Write your one-line Step 0 restatement of the task (NOT the verbatim prompt)."
elif [ "$intent_draft" = "true" ]; then
    msg="$msg
  - intent: still a [DRAFT] copy of the prompt. Rewrite it in your own words — what the user actually wants to achieve and why. Remove the [DRAFT] prefix."
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
This nudge re-fires on each new file edit until the contract is filled (nudge $nudge_count of $nudge_cap)."

emit_json additional_context "$msg"
exit 0
