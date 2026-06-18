#!/usr/bin/env bash
# anchor-set-nudge.sh - afterFileEdit "pre-compile" nudge (Cursor, Linux).
#
# Proactive counterpart to the reactive audits. On the FIRST file edit of an
# agent turn, remind the agent to compile its Anchor Set (pre-compile.md) and
# write .scope.json BEFORE piling on more code. The reactive stack (self-review,
# anti-slop, final-review) only fires AFTER code exists; this nudge catches
# intent dilution at token ~50, not at the ~5000 of the stop-hook axis 0. A
# clean final review of the wrong feature is still the wrong feature - the
# Anchor Set exists so the right feature is on the rails from the first edit.
#
# Fires ONCE PER TURN (per conversation): gated by an anchor-declared-<cid>.flag
# in the pending dir, armed here on first edit and cleared UNCONDITIONALLY by
# final-review.sh / subagent-stop-review.sh on every stop. So a long
# conversation with N turns gets up to N nudges - every new turn re-earns the
# reminder on its first edit. The clear is unconditional (not gated on the
# reviewed-flag path) so the latch can never get stranded silenced mid-session,
# which would silently stop reminding the agent to write .scope.json.
#
# Advisory only: never blocks, never reads the diff, ALWAYS exits 0. Appends to
# the shared feedback-<cid>.txt bus; post-tool-use.sh delivers it next turn.
# Disable: HOOKS_ENFORCE=0  or  ANCHOR_NUDGE_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${ANCHOR_NUDGE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

file_path=""
for k in file_path path filePath; do
    file_path="$(json_get "$input" "$k")"
    [ -n "$file_path" ] && break
done
[ -n "$file_path" ] || exit 0
is_cursor_config_path "$file_path" && exit 0

cid="$(safe_conversation_id "$input")"
pending_dir="$(hooks_pending_dir)"
flag="$pending_dir/anchor-declared-$cid.flag"

# Already nudged this implementation -> stay quiet. The flag is cleared at the
# per-implementation boundary in final-review.sh / subagent-stop-review.sh.
[ -f "$flag" ] && exit 0

msg="PRE-COMPILE NUDGE - first edit of this implementation: $file_path

Before you keep going, did you compile your Anchor Set (pre-compile.md)?
  1. OBJECTIVE   - one operational sentence. What is strictly necessary.
  2. CONSTRAINTS - local negations (what you will NOT do).
  3. SCOPE       - files to touch, files untouchable.
  4. SUCCESS     - the one deterministic check that decides done.

If you have not already, write it to .scope.json now (intent / files /
acceptance / allow_growth). The scope-gate audits every edit against files[],
and final-review axis 0 traces every diff hunk back to intent. An Anchor Set
that lives only in your head is not an Anchor Set - the gate cannot audit it.

Skip this for trivial one-liners (typo, literal). Otherwise: compile, then code."

# Append to the shared pending file (same bus as the other advisories).
pending="$pending_dir/feedback-$cid.txt"
mkdir -p "$pending_dir" 2>/dev/null
if [ -s "$pending" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending" 2>/dev/null
fi

# Arm the one-shot brake BEFORE returning, so a crash after the append can't
# re-nudge on the next edit. Mirrors the arming order in final-review.sh.
touch "$flag" 2>/dev/null

exit 0
