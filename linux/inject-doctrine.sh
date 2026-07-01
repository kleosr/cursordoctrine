#!/usr/bin/env bash
# inject-doctrine.sh - Cursor sessionStart injection (Linux).
#
# Emits {"additional_context": "<doctrine>"} as compact, ASCII-escaped JSON.
# Writes session-start-<cid>.txt so scope-git-sweep can filter by mtime.
# Fail open: missing files or any error -> "{}" (valid, empty).

set +e
. "$HOME/.agents/hooks/hook-common.sh" 2>/dev/null || {
    cat >/dev/null; printf '{}'; exit 0; }

input="$(read_hook_stdin)"
[ -n "$input" ] && write_session_start_stamp "$input"

if [ -f "$HOME/.cursor/doctrine.md" ]; then
    context="$(cat "$HOME/.cursor/doctrine.md")"
else
    printf '{}'
    exit 0
fi

[ -n "$context" ] || { printf '{}'; exit 0; }

emit_json additional_context "$context"
exit 0
