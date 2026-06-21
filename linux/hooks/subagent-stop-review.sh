#!/usr/bin/env bash
# subagent-stop-review.sh - subagentStop for Cursor (Linux).
#
# Counterpart of final-review.sh for delegated work. afterFileEdit DOES fire
# inside subagents (verified: a subagent run left its edits in
# session-edits-<subagent-cid>.txt), but subagents get no `stop` event, so
# that marker is never drained and the seven-axis review never fires for
# delegated implementations. This hook closes the loop: when a subagent
# finishes and edited files, return ONE followup_message so the subagent
# audits its own implementation before the result goes back to the parent.
#
# NO matcher on subagentStop: fires for every subagent type, but a read-only
# subagent (explore/shell that never edits) has no marker and no
# modified_files, so it emits {} and stays silent. Editing-capable types
# (generalPurpose, Cursor's internal poteto/best-of-N/manual-edit, and any
# future type) are all covered without depending on undocumented type names.
#
# Edit detection is BELT-AND-SUSPENDERS (see the inline block): the
# per-cid marker (authoritative, drained on read) UNION the modified_files[]
# field Cursor puts in the subagentStop payload (cid-independent). The
# payload fallback covers the case where subagentStop surfaces the PARENT's
# conversation_id instead of the subagent's - the marker lookup would miss,
# but modified_files still names the files. If both are empty, nothing was
# edited -> silent.
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
# id afterFileEdit used, the marker lookup misses - but the modified_files[]
# payload fallback (below) + the marker fold in post-tool-use.sh /
# final-review.sh (which scans the subagents/ dir, cid-independent) still
# route the subagent's edits into review. Belt and suspenders.
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
intent_latch="$pending_dir/intent-injected-$cid.flag"

# Unconditionally clear the intent-anchor per-turn latch so the next subagent
# run re-fires. Clearing here (not only inside the reviewed-flag block below)
# can never strand it silenced. last-query-<cid>.hash is kept (cross-turn
# prompt-change detect).
rm -f "$intent_latch" 2>/dev/null

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

# Edits this run: AUTHORITATIVE marker (drained) + modified_files payload fallback.
# The marker is populated by self-review-trigger on each afterFileEdit inside the
# subagent. If subagentStop's conversation_id matches the one afterFileEdit used,
# the marker is here and is the most accurate ledger (the hook saw every edit).
# If the cids DON'T match (Cursor may surface the parent's cid in subagentStop),
# fall back to the modified_files[] array Cursor puts in the subagentStop payload
# itself - that signal is cid-independent. Either source alone is enough; union
# both so a delegated implementation is never silently skipped. No edits at all
# (read-only explore/shell subagents) -> {}.
edited=""
if [ -f "$marker" ]; then
    edited="$(grep -vE '^[[:space:]]*$' "$marker" 2>/dev/null | sort -u)"
    rm -f "$marker" 2>/dev/null   # drain (self-reviewed)
fi
mf="$(json_get_array "$input" modified_files 2>/dev/null | grep -vE '^[[:space:]]*$' | sort -u)"
if [ -n "$mf" ]; then
    edited="$(printf '%s\n%s\n' "$edited" "$mf" | grep -vE '^[[:space:]]*$' | sort -u)"
fi
[ -n "$edited" ] || emit_none

# Compose the follow-up review prompt (md preferred, embedded fallback).
prompt_file="$HOME/.agents/hooks/final-review.md"
body=""
[ -f "$prompt_file" ] && body="$(cat "$prompt_file")"
if [ -z "$body" ]; then
    body='Audit everything you changed in this run and FIX what fails (do NOT revert the
behaviour the task asked for). Seven axes, in order:
  0. Intent trace - tie every diff hunk back to your original task. Untraceable = hallucinated.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled, no swallowed errors, resources released.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present.
  4. Anti-slop - the ANTI-SLOP SCAN block in the header is scoped to the files
     you changed (NOT --all): fix those hits on lines you added. If absent, run
     the scanner on <the files above> (never --all at review time). Then read
     ~/.agents/hooks/anti-slop.md (single source of truth) and apply all items.
  5. Wiring completeness - trace every added behavior to a REAL EFFECT (persist/mutate/call/render).
     A dead end (handleSubmit that doesn'"'"'t persist, an endpoint no caller invokes) is slop.
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
# Session-scoped anti-slop scan over ONLY the files changed this run (NOT --all,
# which audits the whole pre-existing codebase - not actionable here).
gate_root="$(resolve_project_root "$input")"
slop_block="$(session_slop_block "$edited" "$gate_root")"
msg="SUBAGENT FINAL REVIEW - you just finished delegated implementation work. Before your result returns to the parent agent, audit it.

Files you changed this run:
$file_list

${slop_block}${body}${reentry_line}"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
touch "$flag" 2>/dev/null

emit_json followup_message "$msg"
exit 0
