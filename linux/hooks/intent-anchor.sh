#!/usr/bin/env bash
# intent-anchor.sh - postToolUse "thin intent compilation" anchor (Cursor, Linux).
#
# Counteracts Salience Dilution: the failure mode where the agent's original
# intent erodes as the conversation fills with code, logs and errors, until the
# token of the original request is a rounding error against the recent history
# and the agent drifts ("forgets" symmetry, colors, the .scope.json it wrote at
# prompt 1). Two jobs, both on the FIRST tool boundary of each turn (per-turn
# latch intent-injected-<cid>.flag, armed here, cleared at every stop):
#
#   1. RE-INJECT .scope.json (the core anti-dilution move): read the contract
#      (intent + files + acceptance) and stash it in the feedback bus so
#      post-tool-use.sh delivers it as additional_context at the next tool
#      boundary. This puts the contract back in the model's attentional focus
#      at the START of each turn's work, before edits pile up and dilute the
#      original intent. Works UNCONDITIONALLY - no transcript needed.
#
#   2. RE-COMPILE ON PROMPT CHANGE: hash the current <user_query> (via
#      extract_last_user_query, which reads the transcript) and compare to
#      last-query-<cid>.hash. If they differ and a valid .scope.json exists,
#      demand the agent UPDATE it. If no valid .scope.json exists and the query
#      is available, WRITE a deterministic scaffold to disk (intent = query,
#      files/acceptance = TODO placeholders) so re-injection always has real
#      content from the first tool boundary — contract creation is not left to
#      the LLM alone.
#
# Why postToolUse, not afterFileEdit: afterFileEdit only fires AFTER an edit
# exists, and Cursor has no preToolUse for file edits. postToolUse fires after
# EVERY tool (Read/Glob/Bash/Write/...), so its first fire of a turn is the
# earliest moment the agent has begun working - typically right after the first
# Read/Glob, before any edit. Best available injection point for "before files".
#
# Once per turn: latch armed on first fire, cleared UNCONDITIONALLY at every
# stop (final-review.sh). Cannot strand silenced mid-session. Registered first
# in the postToolUse array so it appends to the feedback bus before
# post-tool-use.sh drains it (same-tool delivery; if reordered, delivery slips
# one tool - still correct).
#
# Advisory only: never blocks, never reads the diff, ALWAYS exits 0. Appends to
# the shared feedback-<cid>.txt bus. Disable: HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_ANCHOR_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

cid="$(safe_conversation_id "$input")"
pending_dir="$(hooks_pending_dir)"
latch="$pending_dir/intent-injected-$cid.flag"
hash_file="$pending_dir/last-query-$cid.hash"

# Already injected this turn -> quiet. Latch cleared at every stop.
[ -f "$latch" ] && exit 0

# --- current request (best-effort; absent in sandboxed runs) -----------------
current_query="$(extract_last_user_query "$input")"
has_query=0
[ -n "$current_query" ] && has_query=1

current_hash=""
prompt_changed=0
if [ "$has_query" = "1" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        current_hash="$(printf '%s' "$current_query" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        current_hash="$(printf '%s' "$current_query" | shasum -a 256 | awk '{print $1}')"
    fi
    prev_hash=""
    [ -f "$hash_file" ] && prev_hash="$(cat "$hash_file" 2>/dev/null)"
    [ "$current_hash" != "$prev_hash" ] && prompt_changed=1
fi

# --- repo root (same resolution as scope-gate-audit.sh) ----------------------
root=""
while IFS= read -r cand; do
    [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
[ -n "$root" ] || root="${CURSOR_PROJECT_DIR:-$HOME}"
root="${root%/}"

# --- read the existing contract (if any) -------------------------------------
scope_exists=0
scope_intent=""
scope_acceptance=""
scope_files=""
scope_path="$root/.scope.json"
if [ -f "$scope_path" ]; then
    # Prefer jq; fall back to python3 (mirrors hook-common.sh degrade policy).
    if have_jq; then
        scope_intent="$(jq -r '.intent // empty' "$scope_path" 2>/dev/null)"
        scope_acceptance="$(jq -r '.acceptance // empty' "$scope_path" 2>/dev/null)"
        scope_files="$(jq -r '(.files // []) | join(", ")' "$scope_path" 2>/dev/null)"
        scope_exists=1
    elif have_py; then
        read -r scope_intent scope_acceptance scope_files <<EOF
$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("intent","") or "")
    print(d.get("acceptance","") or "")
    print(", ".join(d.get("files",[]) or []))
except Exception:
    sys.exit(1)
' "$scope_path" 2>/dev/null)
EOF
        [ $? -eq 0 ] && scope_exists=1 || scope_exists=0
    fi
fi

# --- deterministic scaffold (0.4.4) -------------------------------------------
# When the query is available and there is no valid contract, write .scope.json
# on disk — intent from <user_query>, TODO placeholders for files/acceptance.
scaffold_written=0
should_scaffold=0
[ "$has_query" = "1" ] && [ "$scope_exists" != "1" ] && should_scaffold=1

if [ "$should_scaffold" = "1" ]; then
    if have_py; then
        if python3 -c '
import json, sys
path, intent = sys.argv[1], sys.argv[2]
obj = {
    "intent": intent,
    "files": ["<TODO: list files>"],
    "acceptance": "<TODO: deterministic success check>",
    "allow_growth": False,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False)
' "$scope_path" "$current_query" 2>/dev/null; then
            scaffold_written=1
            scope_exists=1
            scope_intent="$current_query"
            scope_acceptance="<TODO: deterministic success check>"
            scope_files="<TODO: list files>"
        fi
    fi
fi

# --- compose the anchor message ---------------------------------------------
if [ "$has_query" = "1" ]; then
    query_line="$current_query"
else
    query_line="(current request unavailable - no transcript in this event)"
fi

if [ "$scaffold_written" = "1" ]; then
    msg="INTENT ANCHOR (scaffold written to .scope.json) - contract materialized from your request.

  intent:     $scope_intent
  files:      $scope_files
  acceptance: $scope_acceptance

The hook wrote this scaffold to $scope_path — intent is locked from your current
request. Replace the TODO placeholders with real files[] and acceptance before
editing source. The contract is on disk and will be re-injected every turn."
elif [ "$scope_exists" != "1" ]; then
    msg="INTENT ANCHOR (pre-compile) - no .scope.json found in $root.

Current request:
  $query_line

You have NOT compiled your Anchor Set. Before editing files, write .scope.json
in the repo root:
  intent:     one operational sentence (what is strictly necessary)
  files:      the exact files you will touch
  acceptance: the one deterministic check that decides done

Compile it now, then proceed. The scope tracks the request - it is how you stay
on the rails when the conversation gets long."
elif [ "$prompt_changed" = "1" ]; then
    msg="INTENT ANCHOR (pre-compile) - your request changed; .scope.json may be stale.

Current request:
  $query_line

Your existing contract (.scope.json):
  intent:     $scope_intent
  files:      $scope_files
  acceptance: $scope_acceptance

If the current request differs from the intent above, UPDATE .scope.json now
to match what was just asked. When the request moves, the scope moves with it -
do not edit against a contract written for a different request."
else
    # Same prompt continuing (or query unavailable) -> re-inject the contract.
    if [ "$has_query" = "1" ]; then
        drift_note="Every edit this turn must advance intent and stay inside files. acceptance is the bar for done."
    else
        drift_note="(request unavailable to diff against - re-injecting the contract as-is.)"
    fi
    msg="INTENT ANCHOR (re-injected this turn from .scope.json) - your contract. Do not drift from it.

  intent:     $scope_intent
  files:      $scope_files
  acceptance: $scope_acceptance

$drift_note If a constraint above conflicts with what you are about to do, stop
and reconcile - the contract outranks momentum."
fi

# --- stash to the feedback bus (drained by post-tool-use.sh) -----------------
pending="$pending_dir/feedback-$cid.txt"
mkdir -p "$pending_dir" 2>/dev/null
if [ -s "$pending" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending" 2>/dev/null
fi

# --- arm the latch; record the query hash for next-turn change detection -----
touch "$latch" 2>/dev/null
if [ -n "$current_hash" ]; then
    printf '%s' "$current_hash" > "$hash_file" 2>/dev/null
fi

exit 0
