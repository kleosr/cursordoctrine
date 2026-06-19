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
#   2. AUTO-CREATE / REGENERATE .scope.json: when the current <user_query>
#      differs from the contract on disk (no contract yet, OR _intent_hash
#      mismatch), the hook WRITES a scaffold to the REPO ROOT: intent locked
#      from the prompt, files as an EMPTY array (scope-gate-audit.sh fills it
#      mechanically as the agent edits - the agent never maintains files[] by
#      hand), acceptance as a TODO the agent sets. This is the user-requested
#      behavior: every new prompt -> a fresh .scope.json the agent works from.
#      Fixed vs the broken 0.4.4 build: never writes to $HOME (bails if no real
#      root resolves -> no ghost files), regenerates on prompt CHANGE not just
#      on absence.
#   3. RE-INJECT on same-prompt turns: when the query is unchanged (contract
#      already current), the hook re-injects the existing contract into the
#      feedback bus so it stays in the model's attentional focus each turn.
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

# Stale-latch defense: if a previous session died mid-turn without hitting
# stop (Cursor crash, force-quit), the latch can persist and silence this hook
# for the whole next session -> scope never gets created. If the latch is older
# than 2 hours, treat it as orphaned and clear it. Normal clears happen at
# every stop (final-review.sh); this is the backstop for abnormal terminations.
if [ -f "$latch" ]; then
    age_hours=$(( ($(date +%s) - $(stat -c %Y "$latch" 2>/dev/null || stat -f %m "$latch" 2>/dev/null || echo 0)) / 3600 ))
    [ "$age_hours" -ge 2 ] && rm -f "$latch" 2>/dev/null
fi

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

# --- repo root (same resolution as scope-gate-audit.sh, but NO $HOME fallback) -
# We do NOT fall back to $HOME: writing .scope.json into $HOME was the 0.4.4
# "ghost file" bug. If we cannot resolve a real project root, the hook stays
# silent (no scaffold, no demand) rather than litter the user's home dir.
root=""
while IFS= read -r cand; do
    [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
if [ -z "$root" ] && [ -n "$CURSOR_PROJECT_DIR" ] && [ -d "$CURSOR_PROJECT_DIR" ]; then
    root="${CURSOR_PROJECT_DIR%/}"
fi
# No $HOME fallback. If we still have no root, bail (cannot know where to write).
[ -n "$root" ] || exit 0

# --- read the existing contract (if any) -------------------------------------
scope_exists=0
scope_intent=""
scope_acceptance=""
scope_files=""
scope_stale=0    # 1 when the on-disk contract belongs to a DIFFERENT prompt -> regenerate (resets files[])
needs_heal=0     # 1 when a model-written contract matches THIS prompt but lacks _intent_hash -> backfill in place
on_disk_hash=""
scope_path="$root/.scope.json"
if [ -f "$scope_path" ]; then
    # Prefer jq; fall back to python3 (mirrors hook-common.sh degrade policy).
    if have_jq; then
        scope_intent="$(jq -r '.intent // empty' "$scope_path" 2>/dev/null)"
        scope_acceptance="$(jq -r '.acceptance // empty' "$scope_path" 2>/dev/null)"
        scope_files="$(jq -r '(.files // []) | join(", ")' "$scope_path" 2>/dev/null)"
        on_disk_hash="$(jq -r '._intent_hash // empty' "$scope_path" 2>/dev/null)"
        scope_exists=1
    elif have_py; then
        read -r scope_intent scope_acceptance scope_files on_disk_hash <<EOF
$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("intent","") or "")
    print(d.get("acceptance","") or "")
    print(", ".join(d.get("files",[]) or []))
    print(d.get("_intent_hash","") or "")
except Exception:
    sys.exit(1)
' "$scope_path" 2>/dev/null)
EOF
        [ $? -eq 0 ] && scope_exists=1 || scope_exists=0
    fi
    # Staleness, hash-agnostic so it survives MODEL-written contracts:
    #   - hook-written (has _intent_hash): stale when that hash != current query hash.
    #   - model-written (no _intent_hash - the legacy pre-compile.md schema): fall back to
    #     $prompt_changed (current query hash != the per-conversation last-query hash). Prompt
    #     changed (or a new session) => regenerate and RESET files[] (the "arrastre entre
    #     features" fix). Same prompt this session => heal in place (backfill bookkeeping, keep
    #     files[]/acceptance) so the NEXT prompt is detected by hash.
    if [ "$scope_exists" = "1" ] && [ "$has_query" = "1" ]; then
        if [ -n "$on_disk_hash" ]; then
            [ "$on_disk_hash" != "$current_hash" ] && scope_stale=1
        elif [ "$prompt_changed" = "1" ]; then
            scope_stale=1
        else
            needs_heal=1
        fi
    fi
fi

# --- auto-create / regenerate / heal .scope.json ----------------------------
# CREATION does NOT require the query: if there's a root and no scope yet,
# scaffold it NOW with intent=<TODO> (the agent fills it from the chat it's
# already responding to). This was the 0.5.3 bug - creation was gated on
# $hasQuery, so when Cursor didn't surface transcript_path in the first
# postToolUse fire, the scope never got created.
# REGENERATION requires the query: a prompt change is only detectable when we
# can read the request. A fresh scaffold resets files[] -> ".scope fresco por
# prompt, sin arrastre entre features."
regenerated=0
should_create=0
should_regen=0
[ "$scope_exists" != "1" ] && should_create=1
if [ "$has_query" = "1" ] && [ "$scope_exists" = "1" ] && [ "$scope_stale" = "1" ]; then
    should_regen=1
fi
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

if [ "$should_create" = "1" ] || [ "$should_regen" = "1" ]; then
    # intent from the query when available, else a TODO for the agent to fill.
    # trace.query records the verbatim originating request (provenance); empty
    # when there is no transcript to read it from.
    if [ "$has_query" = "1" ]; then
        intent_val="$current_query"
        trace_query="$current_query"
    else
        intent_val="<TODO: state the operational objective - what is strictly necessary>"
        trace_query=""
    fi
    # jq preferred; python3 fallback. Write intent, empty files[], TODO acceptance,
    # trace provenance, and _intent_hash so staleness is self-contained.
    if have_jq; then
        jq -n --arg intent "$intent_val" --arg hash "$current_hash" --arg tq "$trace_query" --arg ts "$now_ts" \
            '{intent:$intent, files:[], acceptance:"<TODO: the one deterministic check that decides done>", allow_growth:false, trace:{query:$tq, ts:$ts}, _intent_hash:$hash, _generated_by:"intent-anchor hook"}' \
            > "$scope_path" 2>/dev/null && regenerated=1
    elif have_py; then
        if I_FILE="$scope_path" I_INTENT="$intent_val" I_HASH="$current_hash" I_TQ="$trace_query" I_TS="$now_ts" python3 -c '
import json, os
obj = {
    "intent": os.environ["I_INTENT"],
    "files": [],
    "acceptance": "<TODO: the one deterministic check that decides done>",
    "allow_growth": False,
    "trace": {"query": os.environ["I_TQ"], "ts": os.environ["I_TS"]},
    "_intent_hash": os.environ["I_HASH"],
    "_generated_by": "intent-anchor hook",
}
with open(os.environ["I_FILE"], "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
' 2>/dev/null; then
            regenerated=1
        fi
    fi
    if [ "$regenerated" = "1" ]; then
        scope_intent="$intent_val"
        scope_acceptance="<TODO: the one deterministic check that decides done>"
        scope_files="(auto-tracked - the scope hook records every file you edit)"
        scope_exists=1
        scope_stale=0
    fi
fi

# HEAL a model-written contract that matches the current prompt but lacks the
# hook's bookkeeping: backfill _intent_hash + trace + _generated_by IN PLACE,
# preserving the model's files[] and acceptance. Without this a contract written
# per the legacy pre-compile.md schema (no _intent_hash) can never go stale, so
# the next prompt never regenerates - the carryover bug. Healing installs the
# hash so the next prompt change is detected by hash like any hook contract.
if [ "$needs_heal" = "1" ] && [ "$regenerated" != "1" ]; then
    if have_jq; then
        healed="$(jq --arg hash "$current_hash" --arg tq "$current_query" --arg ts "$now_ts" \
            '._intent_hash = $hash | .trace //= {query:$tq, ts:$ts} | ._generated_by //= "intent-anchor hook (healed)"' \
            "$scope_path" 2>/dev/null)"
        [ -n "$healed" ] && printf '%s\n' "$healed" > "$scope_path"
    elif have_py; then
        I_FILE="$scope_path" I_HASH="$current_hash" I_TQ="$current_query" I_TS="$now_ts" python3 -c '
import json, os, sys
path = os.environ["I_FILE"]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
d["_intent_hash"] = os.environ["I_HASH"]
d.setdefault("trace", {"query": os.environ["I_TQ"], "ts": os.environ["I_TS"]})
d.setdefault("_generated_by", "intent-anchor hook (healed)")
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
' 2>/dev/null
    fi
fi

# files[] is auto-tracked and starts empty; show something readable until the
# scope hook has recorded the first edit.
[ -n "$scope_files" ] || scope_files="(none yet - auto-tracked as you edit)"

# --- compose the anchor message ---------------------------------------------
# Three states: regenerated this turn (new prompt), no contract (and no query
# to scaffold from), or re-injecting an existing current contract.
if [ "$has_query" = "1" ]; then
    query_line="$current_query"
else
    query_line="(current request unavailable - no transcript in this event)"
fi

if [ "$regenerated" = "1" ]; then
    msg="INTENT ANCHOR (scope regenerated) - .scope.json written for this prompt.

  intent:     $scope_intent
  files:      $scope_files
  acceptance: $scope_acceptance

The hook wrote a fresh scaffold to $scope_path from your current request. intent
is locked from what you just asked. files[] is AUTO-TRACKED - the scope hook
records every file you edit, so do not maintain it by hand. Set acceptance to
the one deterministic check that decides done, THEN proceed. This contract will
be re-injected every turn until your request changes again."
elif [ "$scope_exists" != "1" ]; then
    msg="INTENT ANCHOR (pre-compile) - no .scope.json found in $root, and the current
request was unavailable to scaffold from.

Current request:
  $query_line

Write .scope.json in the repo root yourself:
  intent:     one operational sentence (what is strictly necessary)
  files:      the exact files you will touch
  acceptance: the one deterministic check that decides done"
else
    # Contract exists and matches the current prompt -> re-inject it.
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
