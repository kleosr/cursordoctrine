#!/usr/bin/env bash
# intent-precompile.sh - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# Fires right after the user hits send, BEFORE the agent's first token.
# Hook-owned field: `prompt` (verbatim latest user message).
# Agent-owned fields: `intent` (Step 0 restatement), initial `files[]` blast
# radius, sharpened `acceptance`.
#
# Intent seeding: on topic change or fresh creation, the hook seeds `intent = ""`
# (empty). A blank intent is HONEST — it signals "not done yet" and keeps both
# intent-anchor (postToolUse nudge) and final-review (axis 0 FAIL) re-surfacing
# the gap until the agent rewrites it as a real Step 0 restatement of the SAME
# task, but clearer/better than the verbatim prompt. The hook never writes a
# [DRAFT] copy of the prompt: a verbatim-with-prefix seed looked "filled" to a
# lazy agent and never got regenerated. (Legacy [DRAFT] intents from older
# installs are still detected defensively by intent-anchor / final-review and
# nudged to be rewritten.) On continuation, existing intent is preserved verbatim.
#
# Topic change (automatic Jaccard detection): when the new prompt is dissimilar
# enough from the stored prompt, reset intent/files/decomposition/verifications.
# Continuation: update `prompt` only; preserve intent, files[], acceptance.
#
# Step 0 nudge: when intent is empty/[DRAFT] or acceptance is the default seed,
# stashes STEP 0 CONTRACT to ~/.cursor/.hooks-pending/precompile-<cid>.txt for
# scope-drain on the first postToolUse. Clears intent-anchor throttle so
# edit-time nudges can fire again this turn.
#
# scope-refresh (afterFileEdit) appends edited paths to files[].
# Skips hook-generated auto-submits. Never blocks. Disable:
# HOOKS_ENFORCE=0 or INTENT_PRECOMPILE_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${INTENT_PRECOMPILE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

prompt="$(json_get "$input" prompt)"
prompt="$(printf '%s' "$prompt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$prompt" ] || exit 0

case "$prompt" in
    "FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*|"INTENT REFINEMENT REQUIRED"*|"SCOPE REMINDER"*|"VERIFY MILESTONE"*) exit 0 ;;
esac
if is_plan_mode_event "$input" || is_plan_only_prompt "$prompt"; then
    exit 0
fi

root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"

# Returns "true" when the new prompt is dissimilar enough to treat as a new task.
topic_changed() {
    local new_p="$1" old_p="$2"
    if have_py; then
        NEW_P="$new_p" OLD_P="$old_p" python3 -c '
import os, re, sys

def tokens(p):
    return set(t for t in re.sub(r"[^a-z0-9 ]", " ", p.lower()).split() if t)

def changed(new_p, old_p):
    if not (old_p or "").strip():
        return True
    a, b = tokens(new_p), tokens(old_p)
    if len(a) < 3 or len(b) < 3:
        return False
    inter = len(a & b)
    union = len(a | b)
    if union == 0:
        return False
    try:
        th = float(os.environ.get("INTENT_TOPIC_THRESHOLD", "0.34"))
    except ValueError:
        th = 0.34
    return (inter / union) < th

print("true" if changed(os.environ.get("NEW_P", ""), os.environ.get("OLD_P", "")) else "false")
' 2>/dev/null
        return
    fi
    # jq-only fallback: normalize tokens via tr/sort/comm.
    _token_file() {
        printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | sed '/^$/d' | sort -u
    }
    if [ -z "$(printf '%s' "$old_p" | tr -d '[:space:]')" ]; then
        printf 'true'
        return
    fi
    local tmpdir newf oldf
    tmpdir="$(mktemp -d 2>/dev/null)" || return 1
    newf="$tmpdir/new"; oldf="$tmpdir/old"
    _token_file "$new_p" > "$newf"
    _token_file "$old_p" > "$oldf"
    local nc oc inter union th
    nc="$(wc -l < "$newf" | tr -dc '0-9')"; nc="${nc:-0}"
    oc="$(wc -l < "$oldf" | tr -dc '0-9')"; oc="${oc:-0}"
    if [ "$nc" -lt 3 ] 2>/dev/null || [ "$oc" -lt 3 ] 2>/dev/null; then
        rm -rf "$tmpdir" 2>/dev/null
        printf 'false'
        return
    fi
    inter="$(comm -12 "$newf" "$oldf" | wc -l | tr -dc '0-9')"; inter="${inter:-0}"
    union="$(sort -u "$newf" "$oldf" | wc -l | tr -dc '0-9')"; union="${union:-0}"
    rm -rf "$tmpdir" 2>/dev/null
    if [ "$union" -eq 0 ] 2>/dev/null; then
        printf 'false'
        return
    fi
    th="${INTENT_TOPIC_THRESHOLD:-0.34}"
    awk -v i="$inter" -v u="$union" -v t="$th" 'BEGIN { print (i/u < t+0) ? "true" : "false" }'
}

write_reset_scope() {
    local p="$1"
    if have_jq; then
        jq -nc \
            --arg p "$p" \
            --arg a "$DEFAULT_ACCEPTANCE" \
            '{prompt: $p, intent: "", decomposition: [], verifications: [], files: [], acceptance: $a}' > "$scope_path" 2>/dev/null
    elif have_py; then
        P="$p" A="$DEFAULT_ACCEPTANCE" python3 -c '
import json, os
print(json.dumps({
    "prompt": os.environ["P"],
    "intent": "",
    "decomposition": [],
    "verifications": [],
    "files": [],
    "acceptance": os.environ["A"],
}, indent=2, ensure_ascii=False))' > "$scope_path" 2>/dev/null
    fi
}

write_continuation_scope() {
    local p="$1" raw="$2"
    if have_jq; then
        printf '%s' "$raw" | jq --arg p "$p" '
            .prompt = $p
            | if (.intent | type) != "string" then .intent = "" else . end
            | if (.decomposition | type) != "array" then .decomposition = [] else . end
            | if (.verifications | type) != "array" then .verifications = [] else . end
            | if (.files | type) != "array" then .files = [] else . end
            | if (.acceptance | type) != "string" then .acceptance = "" else . end
            | del(.trace, .allow_growth)
            | with_entries(select(.key | startswith("_") | not))
        ' > "$scope_path" 2>/dev/null
    elif have_py; then
        P="$p" python3 -c '
import json, os, sys
try:
    o = json.load(sys.stdin)
    o["prompt"] = os.environ["P"]
    if not isinstance(o.get("intent"), str):
        o["intent"] = ""
    if not isinstance(o.get("decomposition"), list):
        o["decomposition"] = []
    if not isinstance(o.get("verifications"), list):
        o["verifications"] = []
    if not isinstance(o.get("files"), list):
        o["files"] = []
    if not isinstance(o.get("acceptance"), str):
        o["acceptance"] = ""
    for k in list(o.keys()):
        if k.startswith("_") or k in ("trace", "allow_growth"):
            del o[k]
    print(json.dumps(o, indent=2, ensure_ascii=False))
except Exception:
    pass' <<< "$raw" > "$scope_path" 2>/dev/null
    fi
}

if [ -f "$scope_path" ]; then
    scope_raw="$(cat "$scope_path" 2>/dev/null)"
    old_prompt="$(printf '%s' "$scope_raw" | jq -r '.prompt // empty' 2>/dev/null)"
    if ! have_jq && have_py; then
        old_prompt="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("prompt") or "")
except Exception: pass' 2>/dev/null)"
    fi
    if [ "$(topic_changed "$prompt" "$old_prompt")" = "true" ]; then
        write_reset_scope "$prompt"
        # Clear per-cid nudge throttle flags so the new task gets FRESH nudges.
        # Without this, a topic change within the same conversation leaves stale
        # throttle state from the OLD task (lastCount from the old, larger
        # files[]) that permanently silences intent-anchor and milestone-verify
        # for the new task whenever the new task's file count <= the old task's.
        # This was the root cause of intent staying empty across task switches:
        # the agent got ZERO nudges, not ignored ones.
        _cid="$(safe_conversation_id "$input")"
        if [ -n "$_cid" ]; then
            _pdir="$HOME/.cursor/.hooks-pending"
            rm -f "$_pdir/intent-anchored-$_cid.flag" "$_pdir/decompose-$_cid.flag" 2>/dev/null
        fi
    else
        write_continuation_scope "$prompt" "$scope_raw"
    fi
else
    write_reset_scope "$prompt"
fi

write_precompile_stash() {
    local p="$1"
    local cid raw intent acceptance needs
    cid="$(safe_conversation_id "$input")"
    [ -n "$cid" ] || return 0
    [ -f "$scope_path" ] || return 0
    raw="$(cat "$scope_path" 2>/dev/null)"
    [ -n "$raw" ] || return 0
    if have_jq; then
        intent="$(printf '%s' "$raw" | jq -r '.intent // empty' 2>/dev/null)"
        acceptance="$(printf '%s' "$raw" | jq -r '.acceptance // empty' 2>/dev/null)"
    elif have_py; then
        intent="$(printf '%s' "$raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("intent") or "")
except Exception: pass' 2>/dev/null)"
        acceptance="$(printf '%s' "$raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("acceptance") or "")
except Exception: pass' 2>/dev/null)"
    else
        return 0
    fi
    needs=false
    [ -z "$intent" ] && needs=true
    case "$intent" in "[DRAFT]"*) needs=true ;; esac
    [ -z "$acceptance" ] && needs=true
    [ "$acceptance" = "$DEFAULT_ACCEPTANCE" ] && needs=true
    [ "$needs" = "true" ] || return 0
    _pdir="$HOME/.cursor/.hooks-pending"
    rm -f "$_pdir/intent-anchored-$cid.flag" 2>/dev/null
    _msg="STEP 0 CONTRACT (re-injected at prompt submit): .scope.json was seeded by intent-precompile. Fill agent-owned fields NOW before your first edit:
  - intent: empty — write your one-line restatement (NOT the verbatim prompt)
  - acceptance: sharpen from the default seed to this task's real done-check
  - decomposition[]: declare steps if this task is multi-file or multi-step

Current prompt: $p"
    mkdir -p "$_pdir" 2>/dev/null
    printf '%s' "$_msg" > "$_pdir/precompile-$cid.txt" 2>/dev/null
}

write_precompile_stash "$prompt"

exit 0
