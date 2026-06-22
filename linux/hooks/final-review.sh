#!/usr/bin/env bash
# final-review.sh - stop hook (Cursor, Linux).
#
# ONE end-of-implementation review across six axes (intent, correctness,
# reliability, coverage, anti-slop, wiring). On a clean stop where files
# changed this session, Cursor auto-submits this hook's `followup_message` as
# the next user turn so the model re-audits its whole session diff.
#
# Change detection: `git diff --name-only HEAD` + `git ls-files --others
# --exclude-standard` against the resolved repo root. Zero state on disk.
#
# Bounded:
#   - per-cid reviewed-<cid>.flag: the stop AFTER the review clears it and
#     ends the loop (one review per implementation),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed'.
#
# Always emits valid JSON ({} = no follow-up). Review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

emit_none() { printf '{}'; exit 0; }

[ "${HOOKS_ENFORCE:-}" = "0" ] && emit_none
[ "${FINAL_REVIEW_ENFORCE:-}" = "0" ] && emit_none

input="$(read_hook_stdin)"
[ -n "$input" ] || emit_none

status="$(json_get "$input" status)"
cid="$(safe_conversation_id "$input")"

pending_dir="$HOME/.cursor/.hooks-pending"
flag="$pending_dir/reviewed-$cid.flag"

# Sweep state older than 7 days from sessions that died before their stop hook.
find "$pending_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# One-shot brake: the previous stop emitted the review; clear it and end the loop.
if [ -f "$flag" ]; then
    rm -f "$flag" 2>/dev/null
    emit_none
fi

# Review only a clean completion.
if [ -n "$status" ] && [ "$status" != "completed" ]; then
    emit_none
fi

# Resolve repo root. No root -> no audit scope -> nothing to review.
root="$(resolve_project_root "$input")"
[ -n "$root" ] || emit_none

# Confirm git repo at root.
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || emit_none

# --- collect changed files: tracked diff + untracked new files ----------------
edited_raw="$(git -C "$root" diff HEAD --name-only 2>/dev/null)"
edited_raw="${edited_raw}
$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"

# Dedupe, normalize to repo-relative forward-slash paths.
root_fwd="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"
root_len="${#root_fwd}"
edited=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
        "$root_fwd"/*) p="${p#"$root_fwd"/}" ;;
        "$root_fwd") continue ;;
    esac
    p="${p#/}"
    [ -n "$p" ] || continue
    case "$edited" in
        *"$p"*) ;;  # already present
        *) edited="${edited}${p}"$'\n' ;;
    esac
done <<EOF
$edited_raw
EOF
[ -n "$edited" ] || emit_none

# --- review prompt body (md preferred, embedded fallback) ---------------------
body=""
prompt_file="$HOME/.agents/hooks/final-review.md"
[ -f "$prompt_file" ] && body="$(cat "$prompt_file")"
if [ -z "$body" ]; then
    body='FINAL REVIEW - audit everything you changed this session and FIX what fails
(do NOT revert the behaviour the user asked for):
  0. Intent trace - tie every diff hunk back to the ORIGINAL REQUEST above.
     Anything untraceable is a hallucinated requirement: revert it. Runs FIRST.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present;
     no tautological tests.
  4. Anti-slop - read ~/.agents/hooks/anti-slop.md (single source of truth) and apply
     all items to the session diff.
  5. Wiring completeness - for every user-visible behavior you added/changed,
     trace its execution path to a REAL EFFECT (persist, mutate, call, render).
     A dead end is slop: handleSubmit that does not persist, an endpoint no caller
     invokes, a stub/TODO/console.log standing in for the effect. Wire it now or
     remove the dead half; mark later-stubs with TODO(wire):.
Fix now, re-run tests, then stop. If an axis is clean, say so in one line.'
fi
body="$(expand_agent_paths "$body")"

# --- .scope.json: declarative contract (optional, agent-written at Step 0) ----
# If present, prefer its intent for axis 0 (sharper than transcript extraction)
# and compute the blast-radius diff: declared vs touched.
scope_path="$root/.scope.json"
scope_block=""
declared_note=""
scope_intent=""
if [ -f "$scope_path" ]; then
    scope_raw="$(cat "$scope_path" 2>/dev/null)"
    if [ -n "$scope_raw" ]; then
        if have_jq; then
            scope_prompt="$(printf '%s' "$scope_raw" | jq -r '.prompt // empty' 2>/dev/null)"
            scope_intent="$(printf '%s' "$scope_raw" | jq -r '.intent // empty' 2>/dev/null)"
            scope_acceptance="$(printf '%s' "$scope_raw" | jq -r '.acceptance // empty' 2>/dev/null)"
            declared_json="$(printf '%s' "$scope_raw" | jq -r '.files[]? // empty' 2>/dev/null)"
        elif have_py; then
            scope_prompt="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("prompt") or "")
except Exception: pass' 2>/dev/null)"
            scope_intent="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("intent") or "")
except Exception: pass' 2>/dev/null)"
            scope_acceptance="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("acceptance") or "")
except Exception: pass' 2>/dev/null)"
            declared_json="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try:
    for f in (json.load(sys.stdin).get("files") or []):
        if f and not str(f).strip().startswith("<"): print(f)
except Exception: pass' 2>/dev/null)"
        fi
        [ -n "$scope_acceptance" ] && scope_block="Declared acceptance: ${scope_acceptance}

"
        if [ -n "$declared_json" ]; then
            # Normalize declared paths to repo-relative forward-slash
            declared_norm="$(printf '%s\n' "$declared_json" | sed 's|\\|/|g; s|^/||' | grep -v '^$' | sort -u)"
            # The contract file itself isn't a real edit; exclude from touched
            # so it doesn't read as "touched but not declared".
            touched_norm="$(printf '%s\n' "$edited" | grep -v -i '^\.scope\.json$' | grep -v '^$' | sort -u)"
            missed="$(comm -23 <(printf '%s\n' "$declared_norm") <(printf '%s\n' "$touched_norm"))"
            extra="$(comm -13 <(printf '%s\n' "$declared_norm") <(printf '%s\n' "$touched_norm"))"
            dcount="$(printf '%s\n' "$declared_norm" | grep -c -v '^$')"
            tcount="$(printf '%s\n' "$touched_norm" | grep -c -v '^$')"
            mcount="$(printf '%s\n' "$missed" | grep -c -v '^$')"
            ecount="$(printf '%s\n' "$extra" | grep -c -v '^$')"
            declared_note="Declared scope: ${dcount} file(s); git sees ${tcount} touched."
            if [ "$mcount" -gt 0 ]; then
                declared_note="${declared_note}
  Declared but NOT touched (${mcount}): $(printf '%s\n' "$missed" | grep -v '^$' | head -n 8 | paste -sd, -)"
            fi
            if [ "$ecount" -gt 0 ]; then
                declared_note="${declared_note}
  Touched but NOT declared (${ecount}): $(printf '%s\n' "$extra" | grep -v '^$' | head -n 8 | paste -sd, -)"
            fi
            if [ "$mcount" -eq 0 ] && [ "$ecount" -eq 0 ]; then
                declared_note="${declared_note}
  (matches declared scope)"
            fi
            declared_note="${declared_note}

"
        fi
    fi
fi

# --- intent trace: intent primary, prompt as source, transcript fallback -------
user_query="$scope_intent"
if [ -z "$user_query" ]; then
    user_query="$scope_prompt"
fi
if [ -z "$user_query" ]; then
    user_query="$(extract_last_user_query "$input")"
fi
intent_block=""
if [ -n "$user_query" ]; then
    intent_block="ORIGINAL REQUEST (intent trace):
---
$user_query
---
"
    if [ -n "$scope_intent" ] && [ -n "$scope_prompt" ]; then
        intent_block="${intent_block}User prompt (source): $scope_prompt

"
    else
        intent_block="${intent_block}
"
    fi
fi

# --- change-surface metric ----------------------------------------------------
file_list="$(printf '%s' "$edited" | grep -v '^$' | head -n 30 | sed 's/^/  /')"
unique_files="$(printf '%s' "$edited" | grep -c -v '^$')"
surface_block="Session footprint: ${unique_files} file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.

"

msg="FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop.

${surface_block}${scope_block}${declared_note}${intent_block}Files you changed this session:
$file_list

$body"

# Arm the brake BEFORE emitting, so a crash after emit can't re-fire.
mkdir -p "$pending_dir" 2>/dev/null
touch "$flag" 2>/dev/null

emit_json followup_message "$msg"
exit 0
