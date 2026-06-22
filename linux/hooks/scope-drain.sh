#!/usr/bin/env bash
# scope-drain.sh - postToolUse: drain the stashed scope reminder into additional_context.
#
# Pairs with scope-refresh.sh (afterFileEdit). afterFileEdit output is not
# consumed by Cursor, so scope-refresh writes a per-cid stash file and THIS
# hook delivers it on the next tool boundary. One-shot: the stash is deleted
# on read, so a hook error can't replay it forever.
#
# Fires on every postToolUse. Most fires find no stash (scope-refresh only
# writes one after an actual edit) and emit nothing. No matcher on postToolUse
# is supported by Cursor, so the gate is "stash file exists."
# Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_REFRESH_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
cid="$(safe_conversation_id "$input")"

pending="$HOME/.cursor/.hooks-pending/scope-$cid.txt"
[ -f "$pending" ] || exit 0

msg="$(cat "$pending" 2>/dev/null)"
rm -f "$pending" 2>/dev/null

[ -n "$msg" ] || exit 0
emit_json additional_context "$msg"
exit 0
