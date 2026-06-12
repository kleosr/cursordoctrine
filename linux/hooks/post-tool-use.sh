#!/usr/bin/env bash
# post-tool-use.sh - postToolUse for Cursor (Linux).
#
# Two responsibilities, both message-bus work, keyed by conversation_id so
# concurrent sessions never receive each other's prompts:
#
#   1. Fold completed subagents' session-edits markers into this
#      conversation's marker (postToolUse does NOT fire for the Task tool -
#      verified - so this per-tool-boundary fold is how delegated edits reach
#      the parent's stop-hook final review). When a fold happens, prime the
#      parent to audit the subagent's diff now.
#   2. Drain this conversation's stashed self-review / advisory messages into
#      Cursor's additional_context channel. One-shot delivery.
#
# We do not parse, score, or filter. We do not run any audit. We do not
# block. The model that already produced the edit will, on its next
# turn, do the self-review.

set +e
. "$(dirname "$0")/hook-common.sh"

input="$(read_hook_stdin)"
cid="$(safe_conversation_id "$input")"

fold_note=""
if merge_subagent_edit_markers "$input" "$cid"; then
    fold_note="SUBAGENT WORK DETECTED - a subagent of this conversation edited files (its edits fired hooks in ITS context, not yours). YOU are the auditor of its work: audit its diff (git status / git diff on the files it touched) against ~/.agents/hooks/self-review.md. Fix real bugs; stay silent otherwise. Its files are folded into this conversation's end-of-implementation review."
fi

pending_file="$(hooks_pending_dir)/feedback-$cid.txt"

msg=""
if [ -f "$pending_file" ]; then
    [ -s "$pending_file" ] && msg="$(cat "$pending_file" 2>/dev/null)"
    # One-shot: clear before emitting so a hook error doesn't replay forever.
    rm -f "$pending_file" 2>/dev/null
fi

if [ -n "$fold_note" ]; then
    if [ -n "$msg" ]; then
        msg="$fold_note

---

$msg"
    else
        msg="$fold_note"
    fi
fi
[ -n "$msg" ] || exit 0

emit_json additional_context "$msg"
exit 0
