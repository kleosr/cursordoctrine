#!/usr/bin/env bash
# hook-common.sh - shared helpers for Cursor agent hooks (Linux).
# Source from sibling scripts:  . "$(dirname "$0")/hook-common.sh"
#
# JSON parsing prefers jq; falls back to python3. If neither exists every
# helper degrades to empty output and the hooks fail open (never block).

read_hook_stdin() {
    # Strip a UTF-8 BOM if present and trim surrounding whitespace.
    local raw
    raw="$(cat 2>/dev/null)"
    raw="${raw#$'\xef\xbb\xbf'}"
    printf '%s' "$raw"
}

have_jq() { command -v jq >/dev/null 2>&1; }
# Verify python3 actually runs: on some systems (e.g. Windows Store stubs over
# a Git Bash PATH) python3 exists on PATH but only prints an install notice.
have_py() { command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; }

# json_get <json> <key>  -> string value of a top-level key ('' if absent)
json_get() {
    local json="$1" key="$2"
    [ -n "$json" ] || return 0
    if have_jq; then
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty | tostring' 2>/dev/null
    elif have_py; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
    v = o.get(sys.argv[1])
    if v is not None:
        print(v if isinstance(v, str) else json.dumps(v))
except Exception:
    pass' "$key" 2>/dev/null
    fi
}

# json_get_array <json> <key> -> one element per line (for workspace_roots)
json_get_array() {
    local json="$1" key="$2"
    [ -n "$json" ] || return 0
    if have_jq; then
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k][]? // empty' 2>/dev/null
    elif have_py; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
    for v in (o.get(sys.argv[1]) or []):
        print(v)
except Exception:
    pass' "$key" 2>/dev/null
    fi
}

# emit_json <key> <value>  -> compact, ASCII-escaped {"key":"value"} on stdout
emit_json() {
    local key="$1" value="$2"
    if have_jq; then
        jq -cna --arg k "$key" --arg v "$value" '{($k): $v}' 2>/dev/null && return 0
    fi
    if have_py; then
        K="$key" V="$value" python3 -c '
import json, os
print(json.dumps({os.environ["K"]: os.environ["V"]}, ensure_ascii=True, separators=(",", ":")))' 2>/dev/null && return 0
    fi
    # Last resort: no JSON encoder available -> emit nothing useful but valid.
    printf '{}'
}

# safe_conversation_id <json> -> sanitized conversation_id ('default' if empty)
safe_conversation_id() {
    local cid
    cid="$(json_get "$1" conversation_id | tr -cd 'A-Za-z0-9_-')"
    printf '%s' "${cid:-default}"
}

# resolve_project_root <json> -> project root ('' if none resolves; NO $HOME fallback).
# cwd -> workspace_roots -> CURSOR_PROJECT_DIR. intent-precompile, intent-anchor and
# scope-gate all WRITE into $root/.scope.json; a $HOME fallback there was the 0.4.4
# "ghost file" bug (a contract persisted in the user's profile). Shared here so the
# five hooks that resolve a root can NEVER drift apart again (the drift that left
# three of them still falling back to $HOME). Callers stay silent on ''. Mirrors
# Resolve-ProjectRoot in the windows/.ps1 edition.
resolve_project_root() {
    local input="$1" root="" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
    done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
    if [ -z "$root" ] && [ -n "$CURSOR_PROJECT_DIR" ] && [ -d "$CURSOR_PROJECT_DIR" ]; then
        root="${CURSOR_PROJECT_DIR%/}"
    fi
    printf '%s' "$root"
}

hooks_pending_dir() { printf '%s' "$HOME/.cursor/.hooks-pending"; }

# sha256_hex <text> -> SHA-256 hex. SHARED so intent-precompile (beforeSubmitPrompt)
# and intent-anchor (postToolUse) hash the SAME text the SAME way; otherwise they
# disagree on _intent_hash and postToolUse needlessly rewrites the prompt hook's
# scope. Mirrors the hashing intent-anchor.sh already does (sha256sum|shasum).
sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    fi
}

# is_hook_generated <text> -> 0 (true) if text opens with a hook-generated
# followup header (FINAL REVIEW / SUBAGENT FINAL REVIEW / SELF-REVIEW / INTENT
# ANCHOR / INTENT REFINEMENT REQUIRED), 1 otherwise. Mirrors Test-IsHookGeneratedQuery
# in the windows/.ps1 edition. SHARED so intent-precompile (beforeSubmitPrompt)
# and intent-anchor (postToolUse) agree on what counts as a hook turn: the gate
# followup Cursor resubmits as a user turn must be recognized by BOTH, or the
# one that misses it clobbers .scope.json with review/gate boilerplate (the
# contamination loop). KEEP IN SYNC with HOOK_HDR + the grep filter inside
# extract_last_user_query below (same header list, three representations).
is_hook_generated() {
    case "$1" in
        "FINAL REVIEW (end of implementation)"*|"SUBAGENT FINAL REVIEW"*|"SELF-REVIEW"*|"INTENT ANCHOR"*|"INTENT REFINEMENT REQUIRED"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Path where beforeSubmitPrompt stashes the verbatim user prompt for the turn.
# intent-anchor PREFERS this over transcript parsing: ground-truth request from
# the payload, present on the FIRST postToolUse, immune to <user_query>
# contamination.
current_prompt_path() { printf '%s' "$(hooks_pending_dir)/current-prompt-$1.txt"; }

# stashed_prompt <cid> -> the stashed prompt ('' if none). Only ever holds real
# human prompts - intent-precompile filters hook-generated submits. (The caller's
# command substitution strips the trailing newline.)
stashed_prompt() {
    local p; p="$(current_prompt_path "$1")"
    [ -f "$p" ] && cat "$p" 2>/dev/null
}

# default_acceptance -> the real default the hook seeds so .scope.json NEVER ships
# a bare "<TODO>" (the thing that looks broken and never gets filled). A verifiable
# bar the agent then sharpens to the single deterministic check. ONE place so both
# hooks emit the identical string.
default_acceptance() {
    printf '%s' 'Every change traces to intent; the project typecheck/build and any *.selfcheck pass, and the described problem no longer reproduces. (Sharpen to the one deterministic check.)'
}

# redact_secrets <text> -> portable (sed) secret scrub for text we persist to
# .scope.json / the prompt stash. Mirrors the python redaction in
# extract_last_user_query so the beforeSubmitPrompt path is no leakier.
redact_secrets() {
    printf '%s' "$1" | sed -E \
        -e 's/\bnpm_[A-Za-z0-9]{10,}\b/[REDACTED_NPM_TOKEN]/g' \
        -e 's/\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b/[REDACTED_TOKEN]/g' \
        -e 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g'
}

# is_cursor_config_path <path> -> 0 if the path lives under a .cursor directory
is_cursor_config_path() {
    case "$1" in
        */.cursor/*|*/.cursor|.cursor/*|.cursor) return 0 ;;
        *) return 1 ;;
    esac
}

# Expand ~/ in agent-facing text to an absolute profile path (bash expands ~,
# but stop-hook followups should still emit literals agents can copy-paste).
expand_agent_paths() {
    local text="$1"
    local home="${HOME%/}"
    text="${text//\~\//$home/}"
    printf '%s' "$text"
}

# Normalize a file path for agent prompts (expand ~).
resolve_agent_path() {
    local p="$1"
    case "$p" in
        "~/"*) printf '%s' "$HOME/${p#~/}" ;;
        *) printf '%s' "$p" ;;
    esac
}

# extract_last_user_query <json> -> text of the last *human* <user_query> in this
# conversation's transcript, or '' if there is none. Capped at 2000 chars.
#
# This is the Tier 0 intent-trace primitive: the final-review hook prepends the
# extracted request to its followup so the model must trace every diff hunk back
# to it. Anything untraceable is a hallucinated requirement.
#
# Walks the JSONL backward via tac (preferred) or a portable awk fallback; finds
# the first (last) user record whose content carries a <user_query> tag - SKIPPING
# hook-generated turns. final-review.sh / subagent-stop-review.sh emit a
# {followup_message} that Cursor replays as a user turn (and self-review /
# intent-anchor inject into additional_context); returning one of those would lock
# the review boilerplate into .scope.json as the intent (the contamination loop).
# Hook turns are detected by their fixed headers; if the transcript has been
# trimmed to just the hook turn, recover the real request from the embedded
# "ORIGINAL REQUEST ... --- <request> ---" block.
extract_last_user_query() {
    local json="$1"
    local tp
    tp="$(json_get "$json" transcript_path)"
    [ -n "$tp" ] && [ -f "$tp" ] || return 0

    local reversed
    if command -v tac >/dev/null 2>&1; then
        reversed="$(tac "$tp" 2>/dev/null)"
    else
        # Portable fallback: awk NR table reversed.
        reversed="$(awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' "$tp" 2>/dev/null)"
    fi
    [ -n "$reversed" ] || return 0

    # Pull the text out via python3 if available (handles JSON content arrays);
    # fall back to a pure-grep that handles string-typed content.
    if have_py; then
        printf '%s' "$reversed" | python3 -c '
import json, re, sys
HOOK_HDR = re.compile(r"^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED)", re.M)
EMBEDDED = re.compile(r"ORIGINAL REQUEST[^\r\n]*\r?\n-{3,}\r?\n(.+?)\r?\n-{3,}", re.S)
def redact(q):
    q = re.sub(r"\bnpm_[A-Za-z0-9]{10,}\b", "[REDACTED_NPM_TOKEN]", q)
    q = re.sub(r"\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b", "[REDACTED_TOKEN]", q)
    q = re.sub(r"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+", r"\1=[REDACTED]", q)
    return q
embedded_fallback = ""
try:
    for line in sys.stdin:
        line = line.strip()
        if not line or "\"role\"" not in line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if not isinstance(rec, dict) or rec.get("role") != "user":
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for p in content:
                if isinstance(p, dict) and p.get("type") == "text" and p.get("text"):
                    text += p["text"]
        m = re.search(r"<user_query>\s*(.+?)\s*</user_query>", text, re.S)
        if not m:
            continue
        q = m.group(1).strip()
        # Hook-generated turn -> not the human words. Remember the embedded
        # ORIGINAL REQUEST (latest such turn) and keep walking back.
        if HOOK_HDR.search(q):
            if not embedded_fallback:
                em = EMBEDDED.search(q)
                if em:
                    embedded_fallback = em.group(1).strip()
            continue
        if len(q) > 2000:
            q = q[:2000] + "..."
        print(redact(q))
        break
    else:
        if embedded_fallback:
            if len(embedded_fallback) > 2000:
                embedded_fallback = embedded_fallback[:2000] + "..."
            print(redact(embedded_fallback))
except Exception:
    pass
' 2>/dev/null
        return 0
    fi

    # No python3: best-effort grep for the common case where the user message
    # is the only place <user_query> appears in a line. Imperfect but bounded.
    # Drop hook-generated turns (FINAL REVIEW / SUBAGENT / SELF-REVIEW / INTENT
    # ANCHOR) so we never lock review boilerplate as the intent; take the first
    # surviving human <user_query>.
    printf '%s' "$reversed" |
        grep -oE '<user_query>[^<]*</user_query>' 2>/dev/null |
        sed -E 's@</?user_query>@@g' |
        grep -vE '^[[:space:]]*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED)' 2>/dev/null |
        head -n1 |
        sed -E 's/\bnpm_[A-Za-z0-9]{10,}\b/[REDACTED_NPM_TOKEN]/g' |
        head -c 2000
}

# merge_subagent_edit_markers <json> <parent_cid> -> 0 if anything was folded
#
# Subagent edits fire afterFileEdit under the SUBAGENT's conversation_id, so
# their session-edits markers are invisible to the parent's stop-hook review.
# Subagent transcripts live at <transcripts>/<parent-cid>/subagents/<sub-cid>.jsonl,
# which gives a deterministic parent->subagent mapping: fold each subagent's
# marker into the parent's and remove the original. No-ops when called from a
# subagent context (its transcript_path has no sibling 'subagents' dir).
merge_subagent_edit_markers() {
    local json="$1" parent_cid="$2"
    local tp sub_dir pending_dir parent_marker j scid m folded=1
    tp="$(json_get "$json" transcript_path)"
    [ -n "$tp" ] || return 1
    sub_dir="$(dirname "$tp")/subagents"
    [ -d "$sub_dir" ] || return 1
    pending_dir="$(hooks_pending_dir)"
    parent_marker="$pending_dir/session-edits-$parent_cid.txt"
    for j in "$sub_dir"/*.jsonl; do
        [ -e "$j" ] || continue
        scid="$(basename "$j" .jsonl | tr -cd 'A-Za-z0-9_-')"
        [ -n "$scid" ] || continue
        [ "$scid" = "$parent_cid" ] && continue
        m="$pending_dir/session-edits-$scid.txt"
        [ -f "$m" ] || continue
        mkdir -p "$pending_dir" 2>/dev/null
        grep -vE '^[[:space:]]*$' "$m" 2>/dev/null | sort -u >> "$parent_marker" 2>/dev/null
        rm -f "$m" 2>/dev/null
        folded=0
    done
    return $folded
}

# Session-scoped anti-slop scan for the stop / subagentStop review hooks.
# WHY THIS EXISTS: the review doctrine used to say `scan_slop.py --all`, which
# audits the ENTIRE pre-existing codebase. At review time the model only owns
# the session diff, so a wall of pre-existing slop is NOT its job (Axis 0 /
# Regla R1 forbid the scope creep) -> it fixed ~nothing and the one-shot brake
# ended the loop. Scoping the scan to the files actually changed this session
# makes the output actionable. `--all` is a deliberate manual whole-codebase
# audit, NOT a review-time tool. Echoes a block to embed ('' = unavailable).
# $1 = newline-separated edited paths, $2 = project root (may be empty).
session_slop_block() {
    local edited="$1" root="$2"
    [ -n "$edited" ] || return 0
    local scanner="$HOME/.cursor/skills/anti-slop/scripts/scan_slop.py"
    [ -f "$scanner" ] || return 0
    # Verify the interpreter actually RUNS (a WindowsApps `python3` stub can sit
    # on PATH yet do nothing); try candidates until one executes.
    local py=""
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then
            py="$c"; break
        fi
    done
    [ -n "$py" ] || return 0

    local root_fwd=""
    [ -n "$root" ] && root_fwd="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"

    # Collect project-relative paths (cleaner report; falls back to absolute).
    local collected=""
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        local rp; rp="$(resolve_agent_path "$p")"
        [ -n "$rp" ] || continue
        if [ -n "$root_fwd" ]; then
            case "$rp" in
                "$root_fwd"/*) rp="${rp#"$root_fwd"/}" ;;
                "$root_fwd") continue ;;
            esac
        fi
        collected="${collected}${rp}"$'\n'
    done <<EOF
$edited
EOF
    # Dedupe preserving order, cap at 40.
    local files; files="$(printf '%s' "$collected" | awk 'NF && !seen[$0]++ {print; if(++n>=40) exit}')"
    [ -n "$files" ] || return 0

    local root_arg="$root_fwd"; [ -n "$root_arg" ] || root_arg="."
    # Null-delimit so paths with spaces survive xargs (portable -0).
    local out
    out="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 "$py" "$scanner" --root "$root_arg" 2>/dev/null)" || true
    [ -n "$out" ] || return 0
    local lc; lc="$(printf '%s\n' "$out" | grep -c '')"
    if [ "$lc" -gt 60 ]; then
        out="$(printf '%s\n' "$out" | head -n 60)
... (scan output truncated; run the scanner directly for the full report)"
    fi
    printf 'ANTI-SLOP SCAN (session-scoped to the files you changed this session - NOT --all):\n%s\n\nFix ONLY the hits on lines you added. Pre-existing slop in these files is out of scope (Axis 0 / Regla R1). A whole-codebase audit (--all) is a separate manual task, never part of this review.\n\n' "$out"
}
