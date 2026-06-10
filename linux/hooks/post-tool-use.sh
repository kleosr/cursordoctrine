#!/usr/bin/env bash
# post-tool-use.sh - postToolUse for Cursor (Linux).
#
# Single responsibility: drain this conversation's stashed self-review /
# advisory messages into Cursor's additional_context channel. One-shot
# delivery, keyed by conversation_id so concurrent sessions never receive
# each other's prompts.
#
# We do not parse, score, or filter. We do not run any audit. We do not
# block. The model that already produced the edit will, on its next
# turn, do the self-review.

set +e
. "$(dirname "$0")/hook-common.sh"

input="$(read_hook_stdin)"
cid="$(safe_conversation_id "$input")"

pending_file="$(hooks_pending_dir)/feedback-$cid.txt"

[ -f "$pending_file" ] || exit 0
if [ ! -s "$pending_file" ]; then
    rm -f "$pending_file" 2>/dev/null   # clear the 0-byte leftover
    exit 0
fi

msg="$(cat "$pending_file" 2>/dev/null)"
# One-shot: clear before emitting so a hook error doesn't replay forever.
rm -f "$pending_file" 2>/dev/null
[ -n "$msg" ] || exit 0

emit_json additional_context "$msg"
exit 0
