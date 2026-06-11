#!/usr/bin/env bash
# final-review.sh - stop hook (Cursor, Linux).
#
# ONE comprehensive end-of-implementation review across four axes:
# correctness, reliability, coverage, and anti-slop. When the agent finishes
# an implementation that touched files, Cursor auto-submits this hook's
# `followup_message` as the next user turn, so the model re-audits everything
# it changed this session and FIXES what fails.
#
# Bounded so it can't loop forever:
#   - a per-conversation reviewed-flag: the stop AFTER the review pass clears
#     it and ends the loop (one review per implementation),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only if a file was actually edited this loop (the session-edits marker
#     written by self-review-trigger.sh). Pure Q&A turns get nothing.
# Plus: only on status == 'completed' (not aborted/errored).
#
# Always emits valid JSON ({} = no follow-up). The review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

emit_none() { printf '{}'; exit 0; }

[ "${HOOKS_ENFORCE:-}" = "0" ] && emit_none
[ "${FINAL_REVIEW_ENFORCE:-}" = "0" ] && emit_none

input="$(read_hook_stdin)"
[ -n "$input" ] || emit_none

status="$(json_get "$input" status)"
cid="$(safe_conversation_id "$input")"

pending_dir="$(hooks_pending_dir)"
marker="$pending_dir/session-edits-$cid.txt"
flag="$pending_dir/reviewed-$cid.flag"

# Sweep state from sessions that died before their stop hook ran.
find "$pending_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# One-shot brake: the previous stop for this conversation emitted the review.
if [ -f "$flag" ]; then
    rm -f "$flag" "$marker" 2>/dev/null
    emit_none
fi

# Review only a clean completion; otherwise just clear the marker and stop.
if [ -n "$status" ] && [ "$status" != "completed" ]; then
    rm -f "$marker" 2>/dev/null
    emit_none
fi
# No edits this loop -> nothing to review.
[ -f "$marker" ] || emit_none
edited="$(grep -vE '^[[:space:]]*$' "$marker" 2>/dev/null | sort -u)"
rm -f "$marker" 2>/dev/null
[ -n "$edited" ] || emit_none

# Compose the follow-up review prompt (md preferred, embedded fallback).
prompt_file="$HOME/.agents/hooks/final-review.md"
body=""
[ -f "$prompt_file" ] && body="$(cat "$prompt_file")"
if [ -z "$body" ]; then
    body='FINAL REVIEW - audit everything you changed this session and FIX what fails
(do NOT revert the behaviour the user asked for):
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present;
     no tautological tests.
  4. Anti-slop - if ~/.cursor/skills/anti-slop/scripts/scan_slop.py exists, run
     `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all`; otherwise
     apply ~/.agents/hooks/anti-slop.md to the session diff (a missing scanner
     is not a failure). Consolidate clones/duplicates to one source of truth;
     drop premature abstraction, unneeded deps, redundant comments, dead helpers.
Fix now, re-run the scan + tests, then stop. If an axis is clean, say so in one line.'
fi

file_list="$(printf '%s\n' "$edited" | head -n 30 | sed 's/^/  /')"
msg="FINAL REVIEW (end of implementation) - correctness, reliability, coverage, anti-slop.

Files you changed this session:
$file_list

$body"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
touch "$flag" 2>/dev/null

emit_json followup_message "$msg"
exit 0
