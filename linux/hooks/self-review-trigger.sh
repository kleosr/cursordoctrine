#!/usr/bin/env bash
# self-review-trigger.sh - afterFileEdit for Cursor (Linux).
#
# Single responsibility: when the model just edited a file, hand the
# edit context to the NEXT model turn as additional_context. The model
# is the auditor; the harness is just the message bus.
#
# We DO:
#   - Capture the edited file path.
#   - Record it in the session-edits marker (drained by final-review.sh).
#   - Stash a self-review prompt that primes the model's next turn.
#   - Exit 0 always.
#
# Cursor's afterFileEdit doesn't consume its own output. To actually
# surface the message, post-tool-use.sh re-emits it on the next tool
# boundary. See hooks.json.

set +e
. "$(dirname "$0")/hook-common.sh"

input="$(read_hook_stdin)"

file_path="$(json_get "$input" file_path)"
[ -n "$file_path" ] || file_path="$(json_get "$input" path)"
[ -n "$file_path" ] || file_path="$(json_get "$input" filePath)"
cid="$(safe_conversation_id "$input")"

# Empty path (JSON parse failed, or no file_path field) -> nothing to record.
[ -n "$file_path" ] || exit 0
if is_cursor_config_path "$file_path"; then exit 0; fi

# State is keyed by conversation_id and lives under $HOME, never the project:
# no repo litter, works in workspace-less sessions, and concurrent sessions
# cannot drain each other's prompts.
pending_dir="$(hooks_pending_dir)"
mkdir -p "$pending_dir" 2>/dev/null

# Record this edit for the end-of-implementation review (final-review.sh).
printf '%s\n' "$file_path" >> "$pending_dir/session-edits-$cid.txt" 2>/dev/null

doctrine_file="$HOME/.agents/hooks/self-review.md"
[ -f "$doctrine_file" ] || exit 0
doctrine="$(cat "$doctrine_file")"

msg="SELF-REVIEW TRIGGER - you just edited: $file_path

$doctrine"

pending_file="$pending_dir/feedback-$cid.txt"
if [ -s "$pending_file" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending_file" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending_file" 2>/dev/null
fi

exit 0
