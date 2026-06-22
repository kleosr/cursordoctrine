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
#   - per-cid reviewed-<cid>.flag: armed when a review is emitted; cleared on
#     the post-review stop (hook-generated last turn or loop_count > 0),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed'.
#
# Always emits valid JSON ({} = no follow-up). Review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.
# Debug: FINAL_REVIEW_DEBUG=1 logs exit reason to ~/.cursor/.hooks-pending/last-final-review.log

set +e
. "$(dirname "$0")/hook-common.sh"

emit_none() {
    final_review_debug "${1:-}"
    printf '{}'
    exit 0
}

[ "${HOOKS_ENFORCE:-}" = "0" ] && emit_none kill_switch
[ "${FINAL_REVIEW_ENFORCE:-}" = "0" ] && emit_none kill_switch

input="$(read_hook_stdin)"
[ -n "$input" ] || emit_none no_input

status="$(json_get "$input" status)"
cid="$(safe_conversation_id "$input")"

loop_count="$(json_get "$input" loop_count)"
case "$loop_count" in
    ''|*[!0-9]*) loop_count=0 ;;
esac
loop_limit="${FINAL_REVIEW_LOOP_LIMIT:-2}"
case "$loop_limit" in
    ''|*[!0-9]*) loop_limit=2 ;;
esac

pending_dir="$HOME/.cursor/.hooks-pending"
flag="$pending_dir/reviewed-$cid.flag"

# Sweep state older than 7 days from sessions that died before their stop hook.
find "$pending_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# One-shot brake: post-review stop clears the flag and ends the loop.
# Orphaned flags (review follow-up never ran) are cleared and we continue.
if [ -f "$flag" ]; then
    last_raw="$(extract_last_raw_user_query "$input")"
    if is_hook_generated_query "$last_raw" || [ "$loop_count" -gt 0 ]; then
        rm -f "$flag" 2>/dev/null
        emit_none post_review_cleanup
    fi
    rm -f "$flag" 2>/dev/null
    final_review_debug stale_flag_cleared
fi

[ "$loop_count" -ge "$loop_limit" ] && emit_none loop_limit

# Review only a clean completion.
if [ -n "$status" ] && [ "$status" != "completed" ]; then
    emit_none no_status
fi

# Resolve repo root. No root -> no audit scope -> nothing to review.
root="$(resolve_project_root "$input")"
[ -n "$root" ] || emit_none no_root

# Confirm git repo at root.
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || emit_none no_git

# --- collect changed files: tracked diff + untracked new files ----------------
edited_raw="$(git -C "$root" diff HEAD --name-only 2>/dev/null)"
edited_raw="${edited_raw}
$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"

# Dedupe, normalize to repo-relative forward-slash paths.
root_fwd="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"
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
        *"$p"*) ;;
        *) edited="${edited}${p}"$'\n' ;;
    esac
done <<EOF
$edited_raw
EOF
[ -n "$edited" ] || emit_none no_diff

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
scope_path="$root/.scope.json"
scope_block=""
declared_note=""
role_trace_block=""
scope_intent=""
scope_prompt=""
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
            declared_norm="$(printf '%s\n' "$declared_json" | sed 's|\\|/|g; s|^/||' | grep -v '^$' | sort -u)"
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

        # Role-trace (axis 7): decomposition + verifications. Empty = YAGNI rung 1.
        if have_py; then
            role_trace_block="$(printf '%s\n' "$edited" | SCOPE_RAW="$scope_raw" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ["SCOPE_RAW"])
except Exception:
    sys.exit(0)
decomp = o.get("decomposition") or []
if not decomp:
    sys.exit(0)
verifs = o.get("verifications") or []
verdict_by_step = {}
for v in verifs:
    if isinstance(v, dict) and isinstance(v.get("step"), int):
        verdict_by_step[v["step"]] = str(v.get("verdict") or "")
touched = [l.strip() for l in sys.stdin if l.strip() and l.strip().lower() != ".scope.json"]
touched_set = set(f.lower() for f in touched)
all_expected = set()
for step in decomp:
    if isinstance(step, dict) and step.get("expected_files"):
        for ef in step["expected_files"]:
            all_expected.add(str(ef).replace("\\", "/").lstrip("/").lower())
leakage = [f for f in touched if f.lower() not in all_expected]
lines = [f"Decomposition: {len(decomp)} step(s); verdicts recorded: {len(verdict_by_step)}."]
for step in decomp:
    if not isinstance(step, dict):
        continue
    sn = step.get("step")
    if not isinstance(sn, int):
        continue
    subtask = step.get("subtask") or "(no subtask)"
    expected = [str(f).replace("\\", "/").lstrip("/") for f in (step.get("expected_files") or [])]
    missing = [ef for ef in expected if ef.lower() not in touched_set]
    verdict = verdict_by_step.get(sn, "(no verdict)")
    if missing:
        status = f"missing {len(missing)} expected"
    elif verdict == "ACCEPT":
        status = "ACCEPTED"
    elif verdict == "REVISE":
        status = "REVISE open"
    else:
        status = "touched, awaiting verdict"
    lines.append(f"  step {sn} [{status}] - {subtask}")
if leakage:
    shown = ", ".join(leakage[:8])
    lines.append(f"  Touched but NOT in any step'\''s expected_files ({len(leakage)}): {shown}")
print("\n".join(lines))
' 2>/dev/null)"
            if [ -n "$role_trace_block" ]; then
                role_trace_block="${role_trace_block}

"
            fi
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

msg="FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop, role-trace (if decomposed).

${surface_block}${scope_block}${declared_note}${role_trace_block}${intent_block}Files you changed this session:
$file_list

$body"

# Arm the brake BEFORE emitting, so a crash after emit can't re-fire.
mkdir -p "$pending_dir" 2>/dev/null
touch "$flag" 2>/dev/null

final_review_debug emitted
emit_json followup_message "$msg"
exit 0
