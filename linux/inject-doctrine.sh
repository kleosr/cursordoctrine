#!/usr/bin/env bash
# inject-doctrine.sh - Cursor sessionStart injection (Linux).
#
# Emits {"additional_context": "<doctrine>"} as compact, ASCII-escaped JSON
# (jq -a / python ensure_ascii), so multi-byte characters in the doctrine can
# never be mangled by encoding layers.
#
# Fail open: missing files or any error -> "{}" (valid, empty). Never block
# or crash session start.

set +e
. "$HOME/.agents/hooks/hook-common.sh" 2>/dev/null || {
    cat >/dev/null; printf '{}'; exit 0; }

# Drain stdin (Cursor sends session metadata) so the pipe never blocks.
cat >/dev/null

if [ -f "$HOME/.cursor/doctrine.md" ]; then
    context="$(cat "$HOME/.cursor/doctrine.md")"
else
    printf '{}'
    exit 0
fi

[ -n "$context" ] || { printf '{}'; exit 0; }

emit_json additional_context "$context"
exit 0
