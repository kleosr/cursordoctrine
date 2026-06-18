#!/usr/bin/env bash
# final-review.sh - stop hook (Cursor, Linux).
#
# ONE comprehensive end-of-implementation review across six axes:
# intent, correctness, reliability, coverage, anti-slop, and wiring completeness. When the agent finishes
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
anchor_flag="$pending_dir/anchor-declared-$cid.flag"

# Sweep state from sessions that died before their stop hook ran.
find "$pending_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# Unconditionally clear the pre-compile nudge's per-turn latch. Every stop is a
# turn boundary; clearing here (not only inside the reviewed-flag block below)
# guarantees the nudge re-fires on the first edit of the NEXT turn and can never
# get stranded silenced. Clearing it only on the SECOND stop left the nudge
# permanently off for any conversation that never cleanly hit that boundary.
rm -f "$anchor_flag" 2>/dev/null

# One-shot brake: the previous stop for this conversation emitted the review.
if [ -f "$flag" ]; then
    rm -f "$flag" "$marker" 2>/dev/null
    emit_none
fi

# Fold completed subagents' edit markers into this conversation's marker so
# the review covers delegated work (subagent edits fire afterFileEdit under
# the SUBAGENT's conversation_id; postToolUse never fires for the Task tool,
# so this stop-time fold is the terminal backstop after the per-tool fold in
# post-tool-use.sh).
merge_subagent_edit_markers "$input" "$cid"

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
  4. Anti-slop - read ~/.agents/hooks/anti-slop.md and apply all 13 items to
     the session diff. If ~/.cursor/skills/anti-slop/scripts/scan_slop.py exists,
     run `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all` first.
     Consolidate clones; drop premature abstraction, unneeded deps, operational
     slop (retries, await-in-loop, log spam), unjustified files.
  5. Wiring completeness - for every user-visible behavior you added/changed
     (button, submit, API call, route, state transition), trace its execution
     path to a REAL EFFECT (persist, mutate, call, render). A dead end is slop:
     handleSubmit that does not persist, an endpoint no caller invokes, a store
     never consumed, a stub/TODO/console.log standing in for the effect. Wire it
     now or remove the dead half; mark later-stubs with TODO(wire):.
Fix now, re-run the scan + tests, then stop. If an axis is clean, say so in one line.'
fi
body="$(expand_agent_paths "$body")"

# Regla R1 (re-entry): if this review pass is a re-audit after a failed gate or
# axis, suppress History Propagation - the model must NOT build on its own prior
# wrong diff. Reset its prior to the Anchor Set, not to its previous attempt.
reentry_line="

RE-ENTRY RULE (Regla R1): if a gate or axis failed, forget the approach that produced it. Re-read your ORIGINAL REQUEST above and your Anchor Set (.scope.json, if you wrote one). Fix ONLY what is failing. Do not refactor in this pass - that is History Propagation, the exact failure mode the Anchor Set exists to prevent.
"

file_list=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    rp="$(resolve_agent_path "$p")"
    file_list="${file_list}  ${rp}"$'\n'
done <<EOF
$edited
EOF
file_list="$(printf '%s' "$file_list" | head -n 30)"

# Tier 0: extract the last user <user_query> from the transcript so the model
# can trace every diff hunk back to a concrete request. Anything untraceable is
# a hallucinated requirement. Empty when there is no transcript or no
# user_query (sandboxed verify runs, fresh installs) - the axis is then a no-op.
user_query="$(extract_last_user_query "$input")"
intent_block=""
[ -n "$user_query" ] && intent_block="ORIGINAL REQUEST (your last user message, for intent trace):
---
$user_query
---

"

# Tier 5: cross-file change-surface metric. The per-file afterFileEdit audits
# miss the 50-file rename case; this seeds the whole-session footprint so the
# model can judge whether the change surface is proportional to the request.
unique_files="$(printf '%s\n' "$edited" | grep -c -v '^$')"
surface_block="Session footprint: ${unique_files} file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.

"

msg="FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop.

${surface_block}${intent_block}Files you changed this session:
$file_list

${body}${reentry_line}"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
touch "$flag" 2>/dev/null

emit_json followup_message "$msg"
exit 0
