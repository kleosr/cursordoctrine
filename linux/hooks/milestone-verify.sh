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
# expected_files completed; kill switch set. When decomposition is empty BUT the session has
# touched >= 1 file, a DECOMPOSE nudge fires instead (per-cid throttle,
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

# --- decomposition nudge: empty decomposition + >=1 real file ---------------
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
        _nudge="$(read_nudge_flag "$_dflag")"
        _lc="${_nudge%%:*}"
        _nc="${_nudge#*:}"
        [ -z "$_lc" ] && _lc=-1
        [ -z "$_nc" ] && _nc=0
        _fc="$_rfc"
        # Effectively unlimited (was 8 — exhausted mid-session on a 30-file
        # task, leaving decomposition empty with no further signal). A contract
        # that can be emptied by an ignoring agent is worse than a noisy one.
        # Re-nudges still only fire when files[] grows (avoids spam). Override:
        # DECOMPOSE_NUDGE_CAP.
        _decompose_cap="${DECOMPOSE_NUDGE_CAP:-99999}"
        case "$_decompose_cap" in ''|*[!0-9]*) _decompose_cap=99999 ;; esac
        # Re-nudge only when files[] grew since last nudge AND under the cap.
        _fire=false
        if [ "$_lc" -lt 0 ] 2>/dev/null; then _fire=true; fi
        if [ "$_rfc" -gt "$_lc" ] 2>/dev/null; then _fire=true; fi
        if [ "$_nc" -ge "$_decompose_cap" ] 2>/dev/null; then _fire=false; fi
        if [ "$_fire" = true ]; then
            _nc=$((_nc + 1))
            write_nudge_flag "$_dflag" "$_rfc" "$_nc"
            emit_json additional_context "DECOMPOSE: this session has touched $_rfc file(s) but .scope.json has no decomposition[]. The doctrine requires decomposition for any multi-step or multi-file task. Declare it now: each entry needs step (int), subtask (one-line string), and expected_files (array of paths). This nudge re-fires on each new file until decomposition is filled (nudge $_nc of $_decompose_cap). The final review's axis 7 will FAIL on a multi-file task with no decomposition."
            exit 0
        fi
    fi
    # Empty decomposition, trivial or throttled → silent.
    exit 0
fi

have_py || exit 0

# --- python3 path: full verdict scrape + milestone detect --------
# Single python3 pass: phase 1 (scrape verdict, write to .scope.json) +
# phase 2 (detect unverified completed milestone, emit reminder to stdout).
msg="$(SCOPE_RAW="$scope_raw" SCOPE_PATH="$scope_path" INPUT="$input" python3 -c '
import json, os, re, sys

# Atomic .scope.json write: write temp then os.replace. Fixes the truncation
# bug where open("w") truncates the live file before json.dump, so a failed
# write empties the whole contract. ponytail: no cross-process lock here (the
# shell paths use write_scope_json_atomic for that); ceiling = two python
# hooks writing concurrently. Upgrade = flock the temp+replace.
def atomic_write_scope(scope):
    path = os.environ["SCOPE_PATH"]
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(scope, fh, indent=2, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try: os.remove(tmp)
        except Exception: pass

try:
    scope = json.loads(os.environ["SCOPE_RAW"])
except Exception:
    sys.exit(0)

decomp = scope.get("decomposition") or []
if not decomp:
    sys.exit(0)
decomp_steps = set(d.get("step") for d in decomp if isinstance(d, dict) and isinstance(d.get("step"), int))

def norm(p):
    parts = []
    for part in str(p).replace("\\", "/").split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            return ""
        parts.append(part)
    return "/".join(parts)
files = [norm(f) for f in (scope.get("files") or [])]
files = [f for f in files if f]
if not files:
    sys.exit(0)

verifs = scope.get("verifications") or []
verified = set()
recorded_by_step = {}
for v in verifs:
    if isinstance(v, dict) and isinstance(v.get("step"), int):
        verified.add(v["step"])
        recorded_by_step[v["step"]] = v.get("verdict")

def allow_upgrade(step_num, scraped_verdict):
    rv = recorded_by_step.get(step_num)
    if rv is None:
        return True
    if rv == "ACCEPT":
        return False
    if rv == scraped_verdict:
        return False
    return True

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
    pattern_canonical = re.compile(r"\b(ACCEPT|REVISE)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?\s*$", re.M | re.I)
    pattern_ed = re.compile(r"\b(ACCEPTED|REVISED)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?\s*$", re.M | re.I)
    # Loosened phrasings — catch casual model language the canonical regex misses.
    pattern_step_accept = re.compile(r"\bstep\s+(\d+)\s+(accepted|approved|done|complete[ds]?|looks good|good|ok|passes?|passed)\b", re.I)
    pattern_step_revise = re.compile(r"\bstep\s+(\d+)\s+(revise[ds]?|needs?\s+fix|fails?|failed|broken|reject(?:ed)?)\b", re.I)
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
        # Skip final-review report turns so axis lines like
        # "- **7 Role-trace**: FAIL - step 2..." are not scraped as real verdicts.
        if "**Verdict**:" in text:
            continue
        # Strip fenced code blocks so verdict keywords inside examples/quoted
        # output are not scraped as real verdicts.
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        # Rightmost verdict wins: the model may revise within one turn.
        candidates = []
        for m in pattern_canonical.finditer(text):
            candidates.append((m.start(), m.group(1).upper(), int(m.group(2)), (m.group(3) or "").strip()))
        for m in pattern_ed.finditer(text):
            verb = m.group(1).upper()
            candidates.append((m.start(), "ACCEPT" if verb == "ACCEPTED" else "REVISE", int(m.group(2)), (m.group(3) or "").strip()))
        for m in pattern_step_accept.finditer(text):
            candidates.append((m.start(), "ACCEPT", int(m.group(1)), ""))
        for m in pattern_step_revise.finditer(text):
            candidates.append((m.start(), "REVISE", int(m.group(1)), ""))
        if not candidates:
            continue
        candidates.sort(key=lambda c: c[0], reverse=True)
        _, verdict, step_num, diag = candidates[0]
        # Only record verdicts for declared steps; a scraped step not in
        # decomposition[] is hallucinated/stale and would pollute verifications[].
        if step_num > 0 and step_num in decomp_steps and allow_upgrade(step_num, verdict):
            new_verifs = [v for v in verifs if not (isinstance(v, dict) and v.get("step") == step_num)]
            new_verifs.append({"step": step_num, "verdict": verdict, "diagnosis": diag})
            scope["verifications"] = new_verifs
            verified.add(step_num)
            recorded_by_step[step_num] = verdict
            verifs = new_verifs
            atomic_write_scope(scope)
        break

verifs = scope.get("verifications") or []

# --- Phase 2: emit reminder for first unverified completed milestone --------
files_set = set(f.lower() for f in files)
for step in decomp:
    if not isinstance(step, dict):
        continue
    sn = step.get("step")
    if not isinstance(sn, int) or sn in verified:
        continue
    expected = [norm(f) for f in (step.get("expected_files") or [])]
    expected = [f for f in expected if f]
    if not expected:
        continue
    if all(ef.lower() in files_set for ef in expected):
        new_verifs = [v for v in verifs if not (isinstance(v, dict) and v.get("step") == sn)]
        new_verifs.append({"step": sn, "verdict": "PENDING", "diagnosis": "auto: all expected_files touched"})
        scope["verifications"] = new_verifs
        atomic_write_scope(scope)
        subtask = step.get("subtask") or "(no subtask declared)"
        total = len(decomp)
        expected_list = ", ".join(expected)
        print(f"VERIFY MILESTONE step {sn} of {total}\n  subtask: {subtask}\n  expected_files: {expected_list} (all touched; recorded as PENDING in verifications[])\n  Emit \"ACCEPT step {sn}\" to proceed, or \"REVISE step {sn}: <one-line diagnosis>\" to repair.")
        break
' 2>/dev/null)"

if [ -n "$msg" ]; then
    emit_json additional_context "$msg"
fi

exit 0
