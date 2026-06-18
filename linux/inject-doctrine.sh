#!/usr/bin/env bash
# inject-doctrine.sh - Cursor sessionStart injection (Linux).
#
# Emits {"additional_context": "<doctrine + USER-RULES>"} as compact,
# ASCII-escaped JSON (jq -a / python ensure_ascii), so multi-byte characters
# in the doctrine can never be mangled by encoding layers.
#
# Fail open: missing files or any error -> "{}" (valid, empty). Never block
# or crash session start.

set +e
. "$HOME/.agents/hooks/hook-common.sh" 2>/dev/null || {
    cat >/dev/null; printf '{}'; exit 0; }

# Drain stdin (Cursor sends session metadata) so the pipe never blocks.
cat >/dev/null

context=""
for p in "$HOME/.cursor/doctrine.md" "$HOME/.cursor/USER-RULES.md" "$HOME/.cursor/declared-editing.md" "$HOME/.cursor/pre-compile.md"; do
    if [ -f "$p" ]; then
        part="$(cat "$p")"
        if [ -n "$context" ]; then context="$context

$part"; else context="$part"; fi
    fi
done

if [ -z "$context" ]; then printf '{}'; exit 0; fi

emit_json additional_context "$context"
exit 0
