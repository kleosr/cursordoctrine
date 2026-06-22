#!/usr/bin/env bash
# scope-refresh.sh - afterFileEdit: re-stash .scope.json for scope-drain to deliver.
#
# Per-edit re-injection against Salience Dilution: as a turn fills with code,
# logs and errors, the intent declared at Step 0 shrinks to a rounding error
# and the agent drifts. afterFileEdit fires right after every Write; this hook
# reads the contract and stashes a one-line reminder to the per-cid pending
# file. scope-drain.sh (postToolUse, fires next) delivers it as
# additional_context. Cursor does not consume afterFileEdit output directly,
# which is why the stash-and-drain pair exists.
#
# One state file (scope-<cid>.txt), no hashes, no latches, no per-prompt
# detection. The agent owns .scope.json; this hook only re-surfaces it.
# Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_REFRESH_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

cid="$(safe_conversation_id "$input")"
root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || exit 0

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || exit 0

if have_jq; then
    intent="$(printf '%s' "$scope_raw" | jq -r '.intent // empty' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | jq -r '.acceptance // empty' 2>/dev/null)"
    files_list="$(printf '%s' "$scope_raw" | jq -r '.files // [] | join(", ")' 2>/dev/null)"
elif have_py; then
    intent="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("intent") or "")
except Exception: pass' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("acceptance") or "")
except Exception: pass' 2>/dev/null)"
    files_list="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(", ".join(json.load(sys.stdin).get("files") or []))
except Exception: pass' 2>/dev/null)"
else
    exit 0
fi

[ -n "$files_list" ] || files_list="(none yet)"

msg="SCOPE REMINDER (re-injected after your edit):
  intent: $intent
  files: $files_list"
[ -n "$acceptance" ] && msg="$msg
  acceptance: $acceptance"
msg="$msg

Confirm this edit advances intent and stays inside files[]. If not, reconcile .scope.json or revert."

pending="$HOME/.cursor/.hooks-pending/scope-$cid.txt"
mkdir -p "$(dirname "$pending")" 2>/dev/null
printf '%s' "$msg" > "$pending" 2>/dev/null
exit 0
