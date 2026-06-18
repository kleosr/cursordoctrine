#!/usr/bin/env bash
# subagent-stop-review.sh - subagentStop for Cursor (Linux).
#
# Counterpart of final-review.sh for delegated work. afterFileEdit DOES fire
# inside subagents (verified: a subagent run left its edits in
# session-edits-<subagent-cid>.txt), but subagents get no `stop` event, so
# that marker is never drained and the six-axis review never fires for
# delegated implementations. This hook closes the loop: when a subagent
# finishes and ITS conversation has a session-edits marker, return ONE
# followup_message so the subagent audits its own implementation before the
# result goes back to the parent.
#
# Same bounding pattern as final-review.sh:
#   - marker-gated: no edits in the subagent run -> no review, no noise,
#   - reviewed-<cid>.flag one-shot brake: the stop AFTER the review pass
#     clears flag + marker and ends the loop (one review per implementation;
#     resumed subagents with a second implementation get a second review),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed' when a status field is present.
#
# If subagentStop's stdin carries a conversation_id that doesn't match the
# id afterFileEdit used, the marker lookup misses and this emits {} - the
# marker fold in post-tool-use.sh / final-review.sh still routes the
# subagent's edits into the parent's stop review as the backstop.
#
# Always emits valid JSON ({} = no follow-up). Review body reuses
# final-review.md (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or SUBAGENT_REVIEW_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

emit_none() { printf '{}'; exit 0; }

[ "${HOOKS_ENFORCE:-}" = "0" ] && emit_none
[ "${SUBAGENT_REVIEW_ENFORCE:-}" = "0" ] && emit_none

input="$(read_hook_stdin)"
[ -n "$input" ] || emit_none

status="$(json_get "$input" status)"
cid="$(safe_conversation_id "$input")"

pending_dir="$(hooks_pending_dir)"
marker="$pending_dir/session-edits-$cid.txt"
flag="$pending_dir/reviewed-$cid.flag"
anchor_flag="$pending_dir/anchor-declared-$cid.flag"
intent_latch="$pending_dir/intent-injected-$cid.flag"

# Unconditionally clear the per-turn latches so the next subagent run re-fires.
# Clearing here (not only inside the reviewed-flag block below) can never strand
# them silenced. last-query-<cid>.hash is kept (cross-turn prompt-change detect).
rm -f "$anchor_flag" "$intent_latch" 2>/dev/null

# One-shot brake: the previous subagentStop for this id emitted the review.
if [ -f "$flag" ]; then
    rm -f "$flag" "$marker" 2>/dev/null
    emit_none
fi

# Review only a clean completion; otherwise clear the marker and stop.
if [ -n "$status" ] && [ "$status" != "completed" ]; then
    rm -f "$marker" 2>/dev/null
    emit_none
fi

# No edits this run -> nothing to review.
[ -f "$marker" ] || emit_none
edited="$(grep -vE '^[[:space:]]*$' "$marker" 2>/dev/null | sort -u)"
rm -f "$marker" 2>/dev/null
[ -n "$edited" ] || emit_none

# Compose the follow-up review prompt (md preferred, embedded fallback).
prompt_file="$HOME/.agents/hooks/final-review.md"
body=""
[ -f "$prompt_file" ] && body="$(cat "$prompt_file")"
if [ -z "$body" ]; then
    body='Audit everything you changed in this run and FIX what fails (do NOT revert the
behaviour the task asked for):
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled, no swallowed errors, resources released.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present.
  4. Anti-slop - if ~/.cursor/skills/anti-slop/scripts/scan_slop.py exists, run
     `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all`; otherwise
     apply ~/.agents/hooks/anti-slop.md to the session diff.
If an axis is clean, say so in one line. Then stop.'
fi
body="$(expand_agent_paths "$body")"

# Regla R1 (re-entry): same suppression as final-review.sh. A subagent that
# failed an axis must not build on its own prior wrong diff - reset its prior
# to the Anchor Set, not to its previous attempt.
reentry_line="

RE-ENTRY RULE (Regla R1): if an axis failed, forget the approach that produced it. Re-read your original task and your Anchor Set (.scope.json, if you wrote one). Fix ONLY what is failing. Do not refactor in this pass.
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
msg="SUBAGENT FINAL REVIEW - you just finished delegated implementation work. Before your result returns to the parent agent, audit it.

Files you changed this run:
$file_list

${body}${reentry_line}"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
touch "$flag" 2>/dev/null

emit_json followup_message "$msg"
exit 0
