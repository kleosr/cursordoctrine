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
#   2. AUTO-CREATE / REGENERATE .scope.json (only when the request is READABLE):
#      when the current <user_query> differs from the contract on disk (no
#      contract yet, _intent_hash mismatch, OR a hollow <TODO> placeholder), the
#      hook WRITES a scaffold to the REPO ROOT: intent locked from the prompt,
#      files as an EMPTY array (scope-gate-audit.sh fills it mechanically as the
#      agent edits - the agent never maintains files[] by hand), acceptance as a
#      TODO the agent sets. We NEVER persist a hollow `intent: <TODO>` file: that
#      caused "el .scope.json se escribe solo sin nada" - when transcript_path is
#      absent on postToolUse the hook can't read the request, so a placeholder
#      with an empty _intent_hash got written, looked owned, and never gained the
#      real intent. Unreadable request -> write nothing, emit the pre-compile
#      demand so the AGENT authors the contract. Never writes to $HOME (bails if
#      no real root resolves -> no ghost files).
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

# --- current request ---------------------------------------------------------
# PREFER the prompt stashed by intent-precompile (beforeSubmitPrompt): ground-truth
# request from the payload, present on the FIRST postToolUse, immune to <user_query>
# contamination. Fall back to transcript parsing only when the prompt hook did not
# run. Both share sha256_hex so _intent_hash is consistent across the two hooks.
current_query="$(stashed_prompt "$cid")"
[ -n "$current_query" ] || current_query="$(extract_last_user_query "$input")"
has_query=0
[ -n "$current_query" ] && has_query=1

current_hash=""
prompt_changed=0
if [ "$has_query" = "1" ]; then
    current_hash="$(sha256_hex "$current_query")"
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
scope_hollow=0   # 1 when the on-disk contract has no real intent (empty or a <TODO> placeholder) -> unusable
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
    # Hollow = no real intent on disk: empty, the hook's <TODO> placeholder, OR
    # hook-generated review boilerplate that a stale extractor locked in (the
    # contamination loop - "FINAL REVIEW (end of implementation)..."). A hollow
    # contract is worse than none (it looks owned, so neither hook nor agent fills
    # it). Treat it as unusable: regenerate when the request is readable, else hand
    # the agent the pre-compile demand to author a real one.
    case "$scope_intent" in
        ""|"<TODO"*|"FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*) scope_hollow=1 ;;
    esac
    if [ "$scope_exists" = "1" ] && [ "$has_query" = "1" ]; then
        if [ "$scope_hollow" = "1" ]; then
            scope_stale=1
        elif [ -n "$on_disk_hash" ]; then
            [ "$on_disk_hash" != "$current_hash" ] && scope_stale=1
        elif [ "$prompt_changed" = "1" ]; then
            scope_stale=1
        else
            needs_heal=1
        fi
    fi
fi

# --- auto-create / regenerate / heal .scope.json ----------------------------
# CREATION and REGENERATION both REQUIRE the query. We only ever write a
# contract whose intent we actually know - never a hollow <TODO> scaffold.
# Persisting a placeholder (the 0.5.3 "unconditional creation") caused "el
# .scope.json se escribe solo sin nada": no transcript_path on postToolUse ->
# the hook can't read the request -> intent=<TODO> with empty _intent_hash, a
# file that looks owned and never gains the real intent. Unreadable request ->
# write nothing, emit the pre-compile demand so the AGENT authors the contract.
# A fresh write resets files[] -> ".scope fresco por prompt, sin arrastre."
# (Hollow on-disk contracts are folded into $scope_stale above, so a readable
# request also overwrites them here.)
regenerated=0
should_create=0
should_regen=0
[ "$scope_exists" != "1" ] && [ "$has_query" = "1" ] && should_create=1
if [ "$has_query" = "1" ] && [ "$scope_exists" = "1" ] && [ "$scope_stale" = "1" ]; then
    should_regen=1
fi
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

if [ "$should_create" = "1" ] || [ "$should_regen" = "1" ]; then
    # Both paths require $has_query, so intent is always locked from the request.
    intent_val="$current_query"
    trace_query="$current_query"
    default_acc="$(default_acceptance)"
    # jq preferred; python3 fallback. Write intent, empty files[], a real seeded
    # acceptance (never a bare <TODO>), trace provenance, and _intent_hash so
    # staleness is self-contained.
    if have_jq; then
        jq -n --arg intent "$intent_val" --arg hash "$current_hash" --arg tq "$trace_query" --arg ts "$now_ts" --arg acc "$default_acc" \
            '{intent:$intent, files:[], acceptance:$acc, allow_growth:false, trace:{query:$tq, ts:$ts}, _intent_hash:$hash, _generated_by:"intent-anchor hook"}' \
            > "$scope_path" 2>/dev/null && regenerated=1
    elif have_py; then
        if I_FILE="$scope_path" I_INTENT="$intent_val" I_HASH="$current_hash" I_TQ="$trace_query" I_TS="$now_ts" I_ACC="$default_acc" python3 -c '
import json, os
obj = {
    "intent": os.environ["I_INTENT"],
    "files": [],
    "acceptance": os.environ["I_ACC"],
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
        scope_acceptance="$default_acc"
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

# acceptance is seeded with a real default (never a bare <TODO>), but the default
# is generic - the contract is not fully set until the agent sharpens it to the
# ONE deterministic check. Detect the unsharpened state -> loud demand each turn.
acceptance_demand=""
case "$scope_acceptance" in
    "<TODO"*|*"Sharpen to the one deterministic check"*)
        acceptance_demand="

>> acceptance is still the seeded default. Your FIRST action this turn is a targeted string-replace on .scope.json setting acceptance to the one deterministic check that decides done - then do the work." ;;
esac

if [ "$regenerated" = "1" ]; then
    msg="INTENT ANCHOR (scope regenerated) - .scope.json written for this prompt.

  intent:     $scope_intent
  files:      $scope_files
  acceptance: $scope_acceptance

The hook wrote a fresh scaffold to $scope_path from your current request. intent
is locked from what you just asked. files[] is AUTO-TRACKED - the scope hook
records every file you edit, so do not maintain it by hand. acceptance is seeded
with a sensible default; sharpen it to the one deterministic check, THEN proceed.
This contract will be re-injected every turn until your request changes again.$acceptance_demand"
elif [ "$scope_exists" != "1" ] || [ "$scope_hollow" = "1" ]; then
    if [ "$scope_hollow" = "1" ]; then
        state="the .scope.json in $root is only a <TODO> placeholder (the hook could not read your request to fill it)"
    else
        state="no .scope.json found in $root, and the current request was unavailable to scaffold from"
    fi
    msg="INTENT ANCHOR (pre-compile) - $state.

Current request:
  $query_line

YOU write the real contract to $scope_path now, from THIS conversation, BEFORE
editing source. Do not leave the <TODO> placeholder:
  intent:     one operational sentence - the ACTUAL request (not \"<TODO>\")
  acceptance: the one deterministic check that decides done
  files:      [] (leave empty - the scope hook records every file you edit)

This is the one case where you own the file: once intent is real, the hook
takes over (re-injection + per-prompt regeneration)."
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
and reconcile - the contract outranks momentum.$acceptance_demand"
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
