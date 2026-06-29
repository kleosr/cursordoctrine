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
# Verify-revise loop: the brake flag stores a CONTENT-HASH SIGNATURE of the
# change surface at review time. On the post-review stop, if the signature
# CHANGED (the agent revised based on the review), the review RE-FIRES with
# the new diff. If the signature is the SAME (the agent accepted, no fixes),
# the flag clears and the loop ends. This implements the Trinity verify-revise-
# reverify cycle: review → fix → re-review until the diff stabilizes.
# Bounded by loop_limit (default 3).
#
# The signature is a SHA256 hash of git diff HEAD -- <files[]> (doctrine) or
# git diff HEAD + untracked (non-doctrine). Unlike a file COUNT, this changes
# on in-place edits to existing files — the dominant revision pattern after a
# REVISE verdict. A count-based brake missed in-place edits entirely because
# scope-refresh is append-only (editing an existing files[] entry does not
# change the count), causing the loop to exit without reverify.
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

get_diff_signature() {
    local repo_root="$1" sp="$repo_root/.scope.json"
    local sig=""
    # Untracked files larger than this are skipped from the signature: a 100MB
    # generated artifact would dominate the hash and slow the brake. Trade-off:
    # an in-place edit to a >1MB untracked file is invisible to verify-revise.
    local max_bytes=1048576

    # Helper: hash a string via sha256sum / shasum / md5sum (first available).
    _hash_str() {
        local s="$1"
        [ -n "$s" ] || { printf 'empty'; return; }
        if command -v sha256sum >/dev/null 2>&1; then
            printf '%s' "$s" | sha256sum | cut -d' ' -f1
        elif command -v shasum >/dev/null 2>&1; then
            printf '%s' "$s" | shasum -a 256 | cut -d' ' -f1
        elif command -v md5sum >/dev/null 2>&1; then
            printf '%s' "$s" | md5sum | cut -d' ' -f1
        else
            printf 'wc:%s:%s' "$(printf '%s' "$s" | wc -l | tr -d ' ')" "$(printf '%s' "$s" | wc -c | tr -d ' ')"
        fi
    }

    # Read files[] from .scope.json into a normalized newline-separated list.
    _read_scope_files() {
        if have_jq; then
            jq -r '.files[]? // empty' "$sp" 2>/dev/null
        elif have_py; then
            python3 -c '
import json
try:
    for f in (json.load(open("'"$sp"'")).get("files") or []):
        s = str(f).strip()
        if s and not s.startswith("<") and s != ".scope.json":
            print(s.replace("\\\\", "/").lstrip("/"))
except Exception: pass' 2>/dev/null
        fi
    }

    if git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        if [ -f "$sp" ]; then
            # Doctrine + git: scoped diff + untracked file[] contents.
            local scope_files norm_files
            scope_files="$(_read_scope_files)"
            if [ -n "$scope_files" ]; then
                norm_files="$(printf '%s\n' "$scope_files" | grep -v '^$' | grep -viE '^\.cursor/plans(/|$)' | sort -u)"
                # Build file args array for git diff.
                local files_args=()
                while IFS= read -r p; do
                    [ -n "$p" ] && files_args+=("$p")
                done <<< "$norm_files"
                if [ ${#files_args[@]} -gt 0 ]; then
                    sig="$(git -C "$repo_root" diff HEAD -- "${files_args[@]}" 2>/dev/null)"
                    # Content of untracked files[] entries (not in git diff HEAD).
                    local tracked
                    tracked="$(git -C "$repo_root" ls-files -- "${files_args[@]}" 2>/dev/null | tr '\\' '/' | sed 's|^/||' | sort -u)"
                    while IFS= read -r f; do
                        [ -n "$f" ] || continue
                        if ! printf '%s\n' "$tracked" | grep -qxF "$f" 2>/dev/null; then
                            if [ -f "$repo_root/$f" ] && [ "$(wc -c < "$repo_root/$f" 2>/dev/null || echo 0)" -le "$max_bytes" ]; then
                                sig="${sig}"$'\n'"==U:${f}=="$'\n'"$(cat "$repo_root/$f" 2>/dev/null)"
                            fi
                        fi
                    done <<< "$norm_files"
                fi
            fi
        else
            # Non-doctrine git: full diff + untracked contents.
            dirty_files="$(git -C "$repo_root" diff HEAD --name-only 2>/dev/null; git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null)"
            dirty_files="$(printf '%s\n' "$dirty_files" | grep -v '^$' | grep -viE '^\.cursor/plans(/|$)' | sort -u)"
            if [ -n "$dirty_files" ]; then
                local dirty_args=()
                while IFS= read -r p; do [ -n "$p" ] && dirty_args+=("$p"); done <<< "$dirty_files"
                if [ ${#dirty_args[@]} -gt 0 ]; then
                    sig="$(git -C "$repo_root" diff HEAD -- "${dirty_args[@]}" 2>/dev/null)"
                fi
            fi
            while IFS= read -r u; do
                [ -n "$u" ] || continue
                if [ -f "$repo_root/$u" ] && [ "$(wc -c < "$repo_root/$u" 2>/dev/null || echo 0)" -le "$max_bytes" ]; then
                    sig="${sig}"$'\n'"==U:${u}=="$'\n'"$(cat "$repo_root/$u" 2>/dev/null)"
                fi
            done <<< "$dirty_files"
        fi
    elif [ -f "$sp" ]; then
        # Non-git doctrine: hash file contents from files[].
        local scope_files
        scope_files="$(_read_scope_files)"
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if is_plan_artifact_path "$p"; then
                continue
            fi
            if [ -f "$repo_root/$p" ] && [ "$(wc -c < "$repo_root/$p" 2>/dev/null || echo 0)" -le "$max_bytes" ]; then
                sig="${sig}"$'\n'"==F:${p}=="$'\n'"$(cat "$repo_root/$p" 2>/dev/null)"
            fi
        done <<< "$scope_files"
    fi

    _hash_str "$sig"
}

if [ -f "$flag" ]; then
    last_raw="$(extract_last_raw_user_query "$input")"
    if is_hook_generated_query "$last_raw" || [ "$loop_count" -gt 0 ]; then
        prev_sig="$(cat "$flag" 2>/dev/null)"
        prev_sig="${prev_sig%%$'\n'*}"
        cur_sig="$(get_diff_signature "$root")"
        if [ "$cur_sig" != "$prev_sig" ] && [ "$loop_count" -lt "$loop_limit" ]; then
            prev_short="${prev_sig:0:8}"
            [ -n "$prev_short" ] || prev_short='(none)'
            cur_short="${cur_sig:0:8}"
            final_review_debug "re_review (prev=$prev_short cur=$cur_short loop=$loop_count)"
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
            p="$(scope_relative_path "$p" "$root")"
            [ "$p" = ".scope.json" ] && continue
            is_plan_artifact_path "$p" && continue
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
            dirty="$(git -C "$root" diff HEAD --name-only 2>/dev/null; git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"
            dirty="$(printf '%s\n' "$dirty" | grep -v '^$' | grep -viE '^\.cursor/plans(/|$)')"
            filtered=""
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                if printf '%s\n' "$dirty" | grep -qxF "$p" 2>/dev/null; then
                    filtered="${filtered}${p}"$'\n'
                fi
            done <<< "$edited"
            edited="$filtered"
            [ -n "$(printf '%s' "$edited" | grep -v '^$')" ] || emit_none no_diff
            stat_files=()
            while IFS= read -r p; do
                [ -n "$p" ] && stat_files+=("$p")
            done <<< "$edited"
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
            is_plan_artifact_path "$p" && continue
            case "$edited" in
                *"$p"*) ;;
                *) edited="${edited}${p}"$'\n' ;;
            esac
        done <<EOF
$edited_raw
EOF
        stat_files=()
        while IFS= read -r p; do
            [ -n "$p" ] && stat_files+=("$p")
        done <<< "$edited"
        if [ ${#stat_files[@]} -gt 0 ]; then
            diff_stat="$(git -C "$root" diff HEAD --stat -- "${stat_files[@]}" 2>/dev/null)"
        fi
    fi
fi

[ -n "$(printf '%s' "$edited" | grep -v '^$')" ] || emit_none no_diff

# --- review prompt body (md REQUIRED — no stale fallback) ---------------------
prompt_file="$HOME/.agents/hooks/final-review.md"
if [ ! -f "$prompt_file" ]; then
    # No fallback. The .md is part of the install. If missing, the install is
    # broken — tell the agent to fix it instead of running a degraded review.
    mkdir -p "$pending_dir" 2>/dev/null
    get_diff_signature "$root" > "$flag" 2>/dev/null
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
            declared_norm="$(printf '%s\n' "$declared_json" | sed 's|\\|/|g; s|^/||; s|^\./||' | grep -v '^$' | grep -viE '^\.cursor/plans(/|$)' | sort -u)"
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

        # Role-trace (axis 7): decomposition + verifications. Empty
        # decomposition is YAGNI rung 1 ONLY for a trivial one-liner (<=1 file);
        # for a multi-file task an empty decomposition is a CONTRACT GAP that
        # FAILs axis 7 (the doctrine requires a plan for multi-step work).
        if have_py; then
            role_trace_block="$(printf '%s\n' "$edited" | SCOPE_RAW="$scope_raw" python3 -c '
import json, os, sys
try:
    o = json.loads(os.environ["SCOPE_RAW"])
except Exception:
    sys.exit(0)
decomp = o.get("decomposition") or []
def norm(p):
    parts = []
    for part in str(p).replace("\\", "/").split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            return ""
        parts.append(part)
    return "/".join(parts)
touched = [norm(l.strip()) for l in sys.stdin if l.strip() and l.strip().lower() != ".scope.json"]
touched = [f for f in touched if f]
if not decomp:
    # CONTRACT GAP: multi-file task with no decomposition. Axis 7 FAILs (not SKIP).
    if len(touched) >= 2:
        print("Decomposition: EMPTY for a %d-file task. The doctrine requires a decomposition[] for any multi-step / multi-file change.\n  Declare it now: each entry { step (int), subtask (one-line), expected_files (array of paths) }.\n  Axis 7 (role-trace) will FAIL until decomposition is declared. Trivial one-liners (<=1 file) are the only SKIP." % len(touched))
    sys.exit(0)
verifs = o.get("verifications") or []
verdict_by_step = {}
for v in verifs:
    if isinstance(v, dict) and isinstance(v.get("step"), int):
        verdict_by_step[v["step"]] = str(v.get("verdict") or "")
touched_set = set(f.lower() for f in touched)
all_expected = set()
for step in decomp:
    if isinstance(step, dict) and step.get("expected_files"):
        for ef in step["expected_files"]:
            nef = norm(ef)
            if nef:
                all_expected.add(nef.lower())
leakage = [f for f in touched if f.lower() not in all_expected]
lines = [f"Decomposition: {len(decomp)} step(s); verdicts recorded: {len(verdict_by_step)}."]
for step in decomp:
    if not isinstance(step, dict):
        continue
    sn = step.get("step")
    if not isinstance(sn, int):
        continue
    subtask = step.get("subtask") or "(no subtask)"
    expected = [norm(f) for f in (step.get("expected_files") or [])]
    expected = [f for f in expected if f]
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
# CONTRACT GAP: intent never written (empty or stale [DRAFT] from a legacy
# install). Axis 0 FAILs until the agent writes a one-line Step 0 restatement.
intent_draft=false
case "$scope_intent" in "[DRAFT]"*) intent_draft=true ;; esac
if [ -z "$scope_intent" ] || [ "$intent_draft" = true ]; then
    intent_gap="CONTRACT GAP: .scope.json intent is empty/[DRAFT] - the agent never wrote its Step 0 restatement. Axis 0 (intent trace) will FAIL until you write a one-line restatement of THIS task in your own words (clearer/better than the verbatim prompt, NOT a copy)."
    intent_block="${intent_gap}

${intent_block}"
fi

# --- change-surface metric + minimality signal --------------------------------
file_list="$(printf '%s' "$edited" | grep -v '^$' | head -n 30 | sed 's/^/  /')"
unique_files="$(printf '%s' "$edited" | grep -c -v '^$')"

# Minimality signal: diff churn is the Levenshtein analog. No ground-truth
# minimal edit exists in production, so we flag VOLUME disproportionate to
# the intent's scope and let axis 4 judge whether the change is faithful.
added=0; deleted=0
if [ "$is_git_repo" = true ] && [ -n "$edited" ]; then
    # Build an array from the newline-separated $edited so paths with spaces
    # survive the git arg list (unquoted $edited would split on spaces too).
    edited_arr=()
    while IFS= read -r _p; do [ -n "$_p" ] && edited_arr+=("$_p"); done <<< "$edited"
    if [ "${#edited_arr[@]}" -gt 0 ]; then
        numstat_out="$(git -C "$root" diff --numstat HEAD -- "${edited_arr[@]}" 2>/dev/null)"
        # numstat: "<added>\t<deleted>\t<path>"; '-' for binary files.
        while IFS=$'\t' read -r a d _path; do
            [ -z "$a" ] && continue
            case "$a" in *[!0-9-]*) continue ;; esac
            [ "$a" != "-" ] && added=$((added + a))
            [ "$d" != "-" ] && deleted=$((deleted + d))
        done <<< "$numstat_out"
    fi
fi
churn=$((added + deleted))

# Intent classification by keyword: surgical (bug/fix) expects a tiny diff;
# constructive (add/build/migrate) tolerates more. Neutral uses a mid threshold.
intent_lc="$(printf '%s %s' "$scope_intent" "$scope_prompt" | tr '[:upper:]' '[:lower:]')"
task_kind=neutral
if printf '%s' "$intent_lc" | grep -Eq 'fix|bug|typo|off-by-one|off by one|wrong|incorrect|broken|hotfix|patch|crash|regression|null pointer|exception'; then
    task_kind=surgical
elif printf '%s' "$intent_lc" | grep -Eq 'add|implement|create|build|new feature|migrate|refactor|rewrite|introduce|scaffold|generate|support|enable'; then
    task_kind=constructive
fi

min_flag=false; min_why=""
case "$task_kind" in
    surgical)
        if [ "$unique_files" -gt 3 ] || [ "$churn" -gt 30 ]; then
            min_flag=true; min_why="bug/fix task but ${unique_files} file(s) / ${churn} line(s) churn"
        fi
        ;;
    constructive)
        if [ "$unique_files" -gt 10 ] || [ "$churn" -gt 400 ]; then
            min_flag=true; min_why="large blast radius: ${unique_files} file(s) / ${churn} line(s)"
        fi
        ;;
    *)
        if [ "$unique_files" -gt 5 ] || [ "$churn" -gt 150 ]; then
            min_flag=true; min_why="${unique_files} file(s) / ${churn} line(s) - justify each or trim"
        fi
        ;;
esac

surface_block="Session footprint: ${unique_files} file(s) touched, +${added}/-${deleted} (${churn} churn). Task kind: ${task_kind}."
if [ "$min_flag" = true ]; then
    surface_block="${surface_block}
MINIMALITY FLAG: DISPROPORTIONATE - ${min_why}. Axis 4 (minimality): justify every file/line or trim to the faithful minimal edit."
else
    surface_block="${surface_block}
MINIMALITY: proportionate to intent scope."
fi
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

# Arm the brake: store the current content-hash signature so the post-review
# stop can detect whether the agent revised (signature changed) or accepted.
mkdir -p "$pending_dir" 2>/dev/null
get_diff_signature "$root" > "$flag" 2>/dev/null

final_review_debug emitted
emit_json followup_message "$msg"
exit 0
