#!/usr/bin/env bash
# intent-precompile.sh - beforeSubmitPrompt "contract first" writer (Cursor, Linux).
#
# THE FIX for "el .scope.json se crea casi al final": creation used to live on
# postToolUse (intent-anchor), which fires only AFTER the agent's first tool and
# depends on the transcript becoming readable to detect the prompt. Until then the
# PREVIOUS prompt's intent persisted and the agent worked under it - the scope only
# flipped to the right intent late in the turn.
#
# beforeSubmitPrompt fires "right after the user hits send, before the backend
# request" - BEFORE the agent's first token - and its payload carries the user's
# `prompt` DIRECTLY (no <user_query> extraction, no transcript dependency, no
# hook-followup contamination). So this hook writes .scope.json with the real
# intent up front, making the contract the FIRST artifact of the turn.
#
# Two deterministic jobs:
#   1. STASH the verbatim prompt to current-prompt-<cid>.txt. intent-anchor prefers
#      it over transcript parsing, so both hooks hash the SAME text (sha256_hex)
#      and never fight over _intent_hash.
#   2. WRITE / REGENERATE .scope.json from the prompt when it is new (hash differs)
#      or missing. Same prompt on disk -> leave it (preserve the agent's refined
#      intent / acceptance / files). acceptance is seeded with a real default
#      (default_acceptance), never a bare <TODO>.
#
# Hook-generated submits (auto-submitted final-review / subagent-review followups)
# are SKIPPED: their prompt is review boilerplate, not the user's request.
#
# Never blocks submission; writes files as a side effect and exits 0. Disable:
# HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0 (shares the intent-anchor kill switch).

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_ANCHOR_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# --- the prompt (direct from payload - the whole point of this event) --------
prompt="$(json_get "$input" prompt)"
# trim leading/trailing whitespace
prompt="$(printf '%s' "$prompt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$prompt" ] || exit 0

# Auto-submitted hook followups are not the user's request -> leave the contract.
case "$prompt" in
    "FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*) exit 0 ;;
esac

prompt="$(redact_secrets "$prompt")"

cid="$(safe_conversation_id "$input")"
pending_dir="$(hooks_pending_dir)"

# --- stash the verbatim prompt FIRST (before root resolution) ----------------
# beforeSubmitPrompt can ship a payload WITHOUT cwd/workspace_roots on some
# Cursor builds. We must still capture the verbatim prompt so intent-anchor
# (postToolUse, which DOES carry cwd) writes .scope.json with the RIGHT intent
# on its first fire - instead of falling back to <user_query> parsing that can
# be unreadable or contaminated by hook followups. The stash lives under
# $HOME/.cursor/.hooks-pending (no repo root needed), so it is always safe.
mkdir -p "$pending_dir" 2>/dev/null
printf '%s' "$prompt" > "$(current_prompt_path "$cid")" 2>/dev/null

# --- repo root (shared resolver; NO $HOME fallback - no ghost files) -----------
root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

# --- write / regenerate .scope.json (hash-gated) ------------------------------
current_hash="$(sha256_hex "$prompt")"
scope_path="$root/.scope.json"
on_disk_hash=""
if [ -f "$scope_path" ]; then
    if have_jq; then
        on_disk_hash="$(jq -r '._intent_hash // empty' "$scope_path" 2>/dev/null)"
    elif have_py; then
        on_disk_hash="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("_intent_hash","") or "")
except Exception: pass' "$scope_path" 2>/dev/null)"
    fi
fi

# Same prompt already locked (prior fire this turn, or the agent refined the
# contract) -> leave it. Only (re)write on a NEW or missing/garbage contract.
[ "$on_disk_hash" = "$current_hash" ] && [ -n "$current_hash" ] && exit 0

now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
default_acc="$(default_acceptance)"
if have_jq; then
    jq -n --arg intent "$prompt" --arg hash "$current_hash" --arg ts "$now_ts" --arg acc "$default_acc" \
        '{intent:$intent, files:[], acceptance:$acc, allow_growth:false, trace:{query:$intent, ts:$ts}, _intent_hash:$hash, _generated_by:"intent-precompile hook (beforeSubmitPrompt)"}' \
        > "$scope_path" 2>/dev/null
elif have_py; then
    I_FILE="$scope_path" I_INTENT="$prompt" I_HASH="$current_hash" I_TS="$now_ts" I_ACC="$default_acc" python3 -c '
import json, os
obj = {
    "intent": os.environ["I_INTENT"],
    "files": [],
    "acceptance": os.environ["I_ACC"],
    "allow_growth": False,
    "trace": {"query": os.environ["I_INTENT"], "ts": os.environ["I_TS"]},
    "_intent_hash": os.environ["I_HASH"],
    "_generated_by": "intent-precompile hook (beforeSubmitPrompt)",
}
with open(os.environ["I_FILE"], "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
' 2>/dev/null
fi

exit 0
