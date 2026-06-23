#!/usr/bin/env bash
# final-review.sh - stop hook (Cursor, Linux).
#
# ONE end-of-implementation review across eight axes (0 intent, 1 correctness,
# 2 reliability, 3 coverage, 4 anti-slop, 5 wiring, 6 mechanics, 7 role-trace).
# On a clean stop where files changed this session, Cursor auto-submits this
# hook's `followup_message` as the next user turn so the model re-audits its
# whole session diff.
#
# Change detection (two paths):
#   doctrine project (.scope.json present): `files[]` is the authoritative
#       per-session edit surface (maintained by scope-refresh on every
#       afterFileEdit). Empty files[] = agent made no session edits = no review
#       (read-only turns don't fire). This is the root fix: previously git diff
#       HEAD was preferred, which counted pre-existing uncommitted files the
#       agent only READ as "changed this session".
#   non-doctrine (no .scope.json): `git diff --name-only HEAD` +
#       `git ls-files --others --exclude-standard` (unchanged).
#
# Verify-revise loop: the brake flag stores the changed-file COUNT at review
# time. On the post-review stop, if the count CHANGED (the agent revised based
# on the review), the review RE-FIRES with the new diff. If the count is the
# SAME (the agent accepted, no fixes), the flag clears and the loop ends.
# This implements the Trinity verify-revise-reverify cycle: review → fix →
# re-review until the diff stabilizes. Bounded by loop_limit (default 3).
#
# Review prompt lives in final-review.md (REQUIRED — no stale fallback). If
# missing, emits an error message instead of a degraded review.
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
loop_limit="${FINAL_REVIEW_LOOP_LIMIT:-3}"
case "$loop_limit" in
    ''|*[!0-9]*) loop_limit=3 ;;
esac

pending_dir="$HOME/.cursor/.hooks-pending"
flag="$pending_dir/reviewed-$cid.flag"

# Review only a clean completion.
if [ -n "$status" ] && [ "$status" != "completed" ]; then
    emit_none no_status
fi

# Resolve repo root early — needed by the verify-revise brake.
root="$(resolve_project_root "$input")"
[ -n "$root" ] || emit_none no_root

# Sweep state older than 7 days from sessions that died before their stop hook.
find "$pending_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# --- verify-revise brake: compare current diff to review-time diff ------------
# get_diff_count: count changed files (.scope.json files[] primary; git fallback)
get_diff_count() {
    local repo_root="$1" sp="$repo_root/.scope.json"
    if [ -f "$sp" ]; then
        # Doctrine project: files[] is the per-session edit surface.
        # Empty/missing files[] → 0 (agent made no session edits).
        if have_jq; then
            local n
            n="$(cat "$sp" 2>/dev/null | jq -r '.files[]? // empty' 2>/dev/null | grep -c -v '^$' 2>/dev/null)"
            printf '%s' "${n:-0}"
            return
        elif have_py; then
            local n
            n="$(cat "$sp" 2>/dev/null | python3 -c 'import json,sys
try:
    f=json.load(sys.stdin).get("files") or []
    print(len([x for x in f if x and str(x).strip() and not str(x).strip().startswith("<") and str(x).strip()!=".scope.json"]))
except Exception: print(0)' 2>/dev/null)"
            printf '%s' "${n:-0}"
            return
        fi
        printf '0'
        return
    fi
    # Non-doctrine fallback: git diff + untracked.
    if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        local n
        n="$(git -C "$repo_root" diff HEAD --name-only 2>/dev/null | grep -c -v '^$' 2>/dev/null)"
        n=$((n + $(git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null | grep -c -v '^$' 2>/dev/null)))
        printf '%s' "${n:-0}"
        return
    fi
    printf '0'
}

if [ -f "$flag" ]; then
    last_raw="$(extract_last_raw_user_query "$input")"
    if is_hook_generated_query "$last_raw" || [ "$loop_count" -gt 0 ]; then
        prev_count="$(cat "$flag" 2>/dev/null | tr -dc '0-9')"
        prev_count="${prev_count:-0}"
        cur_count="$(get_diff_count "$root")"
        if [ "$cur_count" != "$prev_count" ] && [ "$loop_count" -lt "$loop_limit" ]; then
            final_review_debug "re_review (prev=$prev_count cur=$cur_count loop=$loop_count)"
            rm -f "$flag" 2>/dev/null
        else
            rm -f "$flag" 2>/dev/null
            emit_none post_review_cleanup
        fi
    fi
    rm -f "$flag" 2>/dev/null
    final_review_debug stale_flag_cleared
fi

[ "$loop_count" -ge "$loop_limit" ] && emit_none loop_limit

# --- collect changed files (.scope.json files[] primary; git fallback) ---------
# Priority:
#   1. .scope.json present → files[] is the authoritative per-session edit
#      surface (maintained by scope-refresh on every afterFileEdit). Empty
#      files[] → agent made no session edits → no_diff (read-only turns don't
#      fire a review). Root fix: previously git diff HEAD was preferred, which
#      counted pre-existing uncommitted files the agent only READ as "changed
#      this session".
#   2. No .scope.json → git diff HEAD + untracked, unchanged.
diff_stat=""
is_git_repo=false
edited=""
scope_path="$root/.scope.json"

if [ -f "$scope_path" ]; then
    # Doctrine project: files[] is the authoritative session-edit surface.
    scope_raw_sc="$(cat "$scope_path" 2>/dev/null)"
    if [ -n "$scope_raw_sc" ]; then
        if have_jq; then
            sc_files="$(printf '%s' "$scope_raw_sc" | jq -r '.files[]? // empty' 2>/dev/null)"
        elif have_py; then
            sc_files="$(printf '%s' "$scope_raw_sc" | python3 -c 'import json,sys
try:
    for f in (json.load(sys.stdin).get("files") or []):
        s = str(f).strip()
        if s and not s.startswith("<"): print(s)
except Exception: pass' 2>/dev/null)"
        fi
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            p="$(printf '%s' "$p" | tr '\\' '/' | sed 's|^/||')"
            [ "$p" = ".scope.json" ] && continue
            case "$edited" in
                *"$p"*) ;;
                *) edited="${edited}${p}"$'\n' ;;
            esac
        done <<EOF
$sc_files
EOF
    fi
    # Diff-stat evidence scoped to the session surface, not the whole tree.
    if [ -n "$(printf '%s' "$edited" | grep -v '^$')" ]; then
        if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
            is_git_repo=true
            mapfile -t stat_files < <(printf '%s' "$edited" | grep -v '^$')
            if [ ${#stat_files[@]} -gt 0 ]; then
                diff_stat="$(git -C "$root" diff HEAD --stat -- "${stat_files[@]}" 2>/dev/null)"
            fi
        fi
    fi
else
    # Non-doctrine fallback: git diff HEAD + untracked (whole tree).
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        is_git_repo=true
        edited_raw="$(git -C "$root" diff HEAD --name-only 2>/dev/null)"
        edited_raw="${edited_raw}
$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"
        diff_stat="$(git -C "$root" diff HEAD --stat 2>/dev/null)"

        # Dedupe, normalize to repo-relative forward-slash paths.
        root_fwd="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"
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
    fi
fi

[ -n "$(printf '%s' "$edited" | grep -v '^$')" ] || emit_none no_diff

# --- review prompt body (md REQUIRED — no stale fallback) ---------------------
prompt_file="$HOME/.agents/hooks/final-review.md"
if [ ! -f "$prompt_file" ]; then
    # No fallback. The .md is part of the install. If missing, the install is
    # broken — tell the agent to fix it instead of running a degraded review.
    unique_files="$(printf '%s' "$edited" | grep -c -v '^$')"
    mkdir -p "$pending_dir" 2>/dev/null
    printf '%s' "$unique_files" > "$flag" 2>/dev/null
    emit_json followup_message "FINAL REVIEW: The review template (~/.agents/hooks/final-review.md) is missing. Your cursordoctrine install is incomplete. Run: npx cursordoctrine install"
    exit 0
fi
body="$(cat "$prompt_file")"
[ -n "$body" ] || emit_none empty_prompt
body="$(expand_agent_paths "$body")"

# --- .scope.json: declarative contract (optional, agent-written at Step 0) ----
# scope_path already resolved above (change-surface block).
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
surface_block="Session footprint: ${unique_files} file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim."
if [ -n "$diff_stat" ]; then
    stat_trimmed="$(printf '%s' "$diff_stat" | tail -1)"
    surface_block="${surface_block}
Diff: ${stat_trimmed}"
fi
surface_block="${surface_block}

"

msg="FINAL REVIEW (end of implementation). Emit a structured bullet report (one line per axis), then fix anything that fails. See the report template below.

${surface_block}${scope_block}${declared_note}${role_trace_block}${intent_block}Files you changed this session:
$file_list

$body"

# Arm the brake: store the current changed-file count so the post-review stop
# can detect whether the agent revised (count changed) or accepted (same).
mkdir -p "$pending_dir" 2>/dev/null
printf '%s' "$unique_files" > "$flag" 2>/dev/null

final_review_debug emitted
emit_json followup_message "$msg"
exit 0
