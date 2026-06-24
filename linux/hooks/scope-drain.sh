#!/usr/bin/env bash
# scope-drain.sh - postToolUse: drain stashed reminders into additional_context.
#
# Pairs with scope-refresh.sh (afterFileEdit) and intent-precompile.sh
# (beforeSubmitPrompt). Delivers precompile-<cid>.txt (Step 0 contract) and/or
# scope-<cid>.txt (per-edit reminder). One-shot: each stash deleted on read.
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

msgs=""
precompile="$HOME/.cursor/.hooks-pending/precompile-$cid.txt"
if [ -f "$precompile" ]; then
    part="$(cat "$precompile" 2>/dev/null)"
    rm -f "$precompile" 2>/dev/null
    if [ -n "$part" ]; then
        msgs="$part"
    fi
fi

pending="$HOME/.cursor/.hooks-pending/scope-$cid.txt"
if [ -f "$pending" ]; then
    part="$(cat "$pending" 2>/dev/null)"
    rm -f "$pending" 2>/dev/null
    if [ -n "$part" ]; then
        if [ -n "$msgs" ]; then
            msgs="$msgs

$part"
        else
            msgs="$part"
        fi
    fi
fi

[ -n "$msgs" ] || exit 0
emit_json additional_context "$msgs"
exit 0
