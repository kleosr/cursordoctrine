#!/usr/bin/env bash
# milestone-verify.sh - postToolUse: tri-role Verifier for doctrine-ultra.
#
# When the agent declares a `decomposition[]` at Step 0 (Thinker), each step's
# `expected_files[]` is the milestone for that step. As the agent edits
# (Worker), scope-refresh records paths into .scope.json's `files[]`. When a
# step's expected_files are ALL in files[] AND no verdict has been recorded
# for that step, this hook emits a VERIFY MILESTONE reminder as
# additional_context.
#
# The agent emits verdicts in chat: "ACCEPT step N" or "REVISE step N:
# <one-line diagnosis>". This hook scrapes the transcript backward through
# assistant turns for the most recent verdict matching a still-unverified
# step, and writes it into .scope.json's `verifications[]` (hook-owned).
#
# Tri-role (Trinity-style): Thinker=decomposition at Step 0,
# Worker=edits+scope-refresh, Verifier=this hook + final-review axis 7.
# Doctrine-ultra: the harness adds structure; the model fills it. The hook
# never decides correctness — only the model does.
#
# Silent exits (YAGNI rung 1): .scope.json missing; all steps verified; no
# expected_files completed; kill switch set; no python3 (verdict-scrape needs
# regex on transcript text; jq alone is not enough — fail open silently, the
# doctrine still applies). When decomposition is empty BUT the session has
# touched >= 2 files, a DECOMPOSE nudge fires instead (per-cid throttle,
# mirrors intent-anchor) — the doctrine requires decomposition for multi-file
# tasks. Never blocks. Disable: HOOKS_ENFORCE=0 or MILESTONE_VERIFY_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${MILESTONE_VERIFY_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || exit 0

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || exit 0

# Need jq or python3 for JSON work. Without either, fail open silently.
have_jq || have_py || exit 0

# --- decomposition nudge: empty decomposition + >=2 real files --------------
# Doctrine requires decomposition for multi-step/multi-file tasks. When the
# agent skips it (many files touched, zero steps declared), nudge once per
# file-count growth. Per-cid flag mirrors intent-anchor's throttle. Silent
# when files[] hasn't grown since last nudge or the nudge cap (3) is hit.
if have_jq; then
    _dl="$(printf '%s' "$scope_raw" | jq -r '(.decomposition // []) | length' 2>/dev/null)"
    _rfc="$(printf '%s' "$scope_raw" | jq -r '[.files[]? // empty | select(. != "" and (test("^\\s*<")|not) and ((. | ltrimstr("/") | ascii_downcase) != ".scope.json"))] | length' 2>/dev/null)"
elif have_py; then
    _dl="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("decomposition") or []))
except Exception: print(0)' 2>/dev/null)"
    _rfc="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try:
    f=json.load(sys.stdin).get("files") or []
    print(len([x for x in f if x and str(x).strip() and not str(x).strip().startswith("<") and str(x).strip().lstrip("/").lower()!=".scope.json"]))
except Exception: print(0)' 2>/dev/null)"
fi
_dl="${_dl:-0}"; _rfc="${_rfc:-0}"
if [ "$_dl" -eq 0 ] 2>/dev/null; then
    if [ "$_rfc" -ge 2 ] 2>/dev/null; then
        _cid="$(safe_conversation_id "$input")"
        _pdir="$HOME/.cursor/.hooks-pending"
        _dflag="$_pdir/decompose-$_cid.flag"
        _lc=-1; _nc=0
        if [ -f "$_dflag" ]; then
            _lc="$(cut -d: -f1 "$_dflag" 2>/dev/null | tr -dc '0-9')"; _lc="${_lc:--1}"
            _nc="$(cut -d: -f2 "$_dflag" 2>/dev/null | tr -dc '0-9')"; _nc="${_nc:-0}"
        fi
        # Re-nudge only when files[] grew since last nudge AND under the cap.
        _fire=false
        if [ "$_lc" -lt 0 ] 2>/dev/null; then _fire=true; fi
        if [ "$_rfc" -gt "$_lc" ] 2>/dev/null; then _fire=true; fi
        if [ "$_nc" -ge 3 ] 2>/dev/null; then _fire=false; fi
        if [ "$_fire" = true ]; then
            _nc=$((_nc + 1))
            mkdir -p "$_pdir" 2>/dev/null
            printf '%s:%s' "$_rfc" "$_nc" > "$_dflag" 2>/dev/null
            emit_json additional_context "DECOMPOSE: this session has touched $_rfc file(s) but .scope.json has no decomposition[]. The doctrine requires decomposition for any multi-step or multi-file task. Declare it now: each entry needs step (int), subtask (one-line string), and expected_files (array of paths). This nudge re-fires on each new file until decomposition is filled (nudge $_nc of 3)."
            exit 0
        fi
    fi
    # Empty decomposition, trivial or throttled → silent.
    exit 0
fi

# --- jq-only path (no python3): verdict scrape + milestone detect -----------
# When python3 is missing, use jq for JSON + grep for transcript scraping.
# This is less robust (no multiline content extraction from JSONL) but catches
# the common case where the verdict appears as a plain string in the transcript.
if ! have_py; then
    # Parse decomposition + files + verifications from .scope.json via jq.
    decomp_len="$(printf '%s' "$scope_raw" | jq -r '.decomposition | length' 2>/dev/null)"
    [ "$decomp_len" -gt 0 ] 2>/dev/null || exit 0

    files_list="$(printf '%s' "$scope_raw" | jq -r '.files[]? // empty' 2>/dev/null)"
    [ -n "$files_list" ] || exit 0

    # Build verified-steps set from existing verifications.
    verified_steps="$(printf '%s' "$scope_raw" | jq -r '.verifications[]? | .step' 2>/dev/null)"

    # Phase 1: grep-based verdict scrape from transcript.
    tp="$(json_get "$input" transcript_path)"
    if [ -n "$tp" ] && [ -f "$tp" ]; then
        # Read transcript backward, find last ACCEPT/REVISE step N in assistant turns.
        if command -v tac >/dev/null 2>&1; then
            reversed="$(tac "$tp" 2>/dev/null)"
        else
            reversed="$(awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' "$tp" 2>/dev/null)"
        fi
        scraped_verdict="$(printf '%s' "$reversed" | grep -oE '(ACCEPT|REVISE)[[:space:]]+step[[:space:]]+[0-9]+' | head -1 2>/dev/null)"
        if [ -n "$scraped_verdict" ]; then
            sv_verb="$(printf '%s' "$scraped_verdict" | grep -oE '^(ACCEPT|REVISE)')"
            sv_step="$(printf '%s' "$scraped_verdict" | grep -oE '[0-9]+')"
            # Only record if not already verified.
            if [ -n "$sv_step" ] && ! printf '%s\n' "$verified_steps" | grep -qx "$sv_step"; then
                # Update .scope.json verifications via jq.
                new_raw="$(printf '%s' "$scope_raw" | jq --argjson sn "$sv_step" --arg verb "$sv_verb" '
                    .verifications = ((.verifications // []) | map(select(.step != $sn)))
                    + [{"step": $sn, "verdict": $verb, "diagnosis": ""}]
                ' 2>/dev/null)"
                if [ -n "$new_raw" ]; then
                    printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
                    scope_raw="$new_raw"
                    verified_steps="$(printf '%s' "$verified_steps""$'\n'"$sv_step")"
                fi
            fi
        fi
    fi

    # Phase 2: detect unverified completed milestone via jq.
    msg="$(printf '%s' "$scope_raw" | jq -r --argjson verified ("[$(printf '%s\n' "$verified_steps" | grep -v '^$' | paste -sd,)]") '
        (.files // []) as $files |
        ($files | map(ltrimstr("/") | ascii_downcase)) as $files_lc |
        ([.decomposition[]?] as $decomp |
        ($decomp | length) as $total |
        first(
            $decomp[] |
            select(.step as $sn | $verified | index($sn) | not) |
            select((.expected_files // []) | length > 0) |
            select(all((.expected_files // [])[]; (. | ltrimstr("/") | ascii_downcase) as $ef | $files_lc | index($ef))) |
            "VERIFY MILESTONE step \(.step) of \($total)\n  subtask: \(.subtask // "(no subtask declared)")\n  expected_files: \((.expected_files // []) | join(", ")) (all touched)\n  Emit \"ACCEPT step \(.step)\" to proceed, or \"REVISE step \(.step): <one-line diagnosis>\" to repair."
        ) // empty
    ' 2>/dev/null)"
    if [ -n "$msg" ]; then
        emit_json additional_context "$msg"
    fi
    exit 0
fi

# --- python3 path (preferred): full verdict scrape + milestone detect --------
# Single python3 pass: phase 1 (scrape verdict, write to .scope.json) +
# phase 2 (detect unverified completed milestone, emit reminder to stdout).
msg="$(SCOPE_RAW="$scope_raw" SCOPE_PATH="$scope_path" INPUT="$input" python3 -c '
import json, os, re, sys

try:
    scope = json.loads(os.environ["SCOPE_RAW"])
except Exception:
    sys.exit(0)

decomp = scope.get("decomposition") or []
if not decomp:
    sys.exit(0)

files = [str(f).replace("\\", "/").lstrip("/") for f in (scope.get("files") or [])]
if not files:
    sys.exit(0)

verifs = scope.get("verifications") or []
verified = set()
for v in verifs:
    if isinstance(v, dict) and isinstance(v.get("step"), int):
        verified.add(v["step"])

# --- Phase 1: scrape most-recent ACCEPT/REVISE from assistant turns ---------
try:
    inp = json.loads(os.environ["INPUT"])
    tp = inp.get("transcript_path") or ""
except Exception:
    tp = ""

if tp and os.path.isfile(tp):
    try:
        with open(tp, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except Exception:
        lines = []
    pattern = re.compile(r"\b(ACCEPT|REVISE)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?\s*$", re.M | re.I)
    for line in reversed(lines):
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if not isinstance(rec, dict):
            continue
        msg_obj = rec.get("message") or rec
        if not isinstance(msg_obj, dict):
            continue
        if msg_obj.get("role") != "assistant" and rec.get("role") != "assistant":
            continue
        content = msg_obj.get("content")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for p in content:
                if isinstance(p, dict) and p.get("type") == "text" and p.get("text"):
                    text += p["text"]
        if not text:
            continue
        m = pattern.search(text)
        if m:
            verdict = m.group(1).upper()
            try:
                step_num = int(m.group(2))
            except Exception:
                continue
            diag = (m.group(3) or "").strip() if m.group(3) else ""
            if step_num > 0 and step_num not in verified:
                new_verifs = [v for v in verifs if not (isinstance(v, dict) and v.get("step") == step_num)]
                new_verifs.append({"step": step_num, "verdict": verdict, "diagnosis": diag})
                scope["verifications"] = new_verifs
                verified.add(step_num)
                try:
                    with open(os.environ["SCOPE_PATH"], "w", encoding="utf-8") as fh:
                        json.dump(scope, fh, indent=2, ensure_ascii=False)
                except Exception:
                    pass
            break

# --- Phase 2: emit reminder for first unverified completed milestone --------
files_set = set(f.lower() for f in files)
for step in decomp:
    if not isinstance(step, dict):
        continue
    sn = step.get("step")
    if not isinstance(sn, int) or sn in verified:
        continue
    expected = [str(f).replace("\\", "/").lstrip("/") for f in (step.get("expected_files") or [])]
    if not expected:
        continue
    if all(ef.lower() in files_set for ef in expected):
        subtask = step.get("subtask") or "(no subtask declared)"
        total = len(decomp)
        expected_list = ", ".join(expected)
        print(f"VERIFY MILESTONE step {sn} of {total}\n  subtask: {subtask}\n  expected_files: {expected_list} (all touched)\n  Emit \"ACCEPT step {sn}\" to proceed, or \"REVISE step {sn}: <one-line diagnosis>\" to repair.")
        break
' 2>/dev/null)"

if [ -n "$msg" ]; then
    emit_json additional_context "$msg"
fi

exit 0
