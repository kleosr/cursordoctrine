#!/usr/bin/env bash
# hook-common.sh - shared helpers for Cursor agent hooks (Linux).
# Source from sibling scripts:  . "$(dirname "$0")/hook-common.sh"
#
# Minimal: only what final-review.sh and inject-doctrine.sh use. No state
# directory, no .scope.json bookkeeping, no subagent folding. JSON parsing
# prefers jq; falls back to python3. If neither exists every helper degrades
# to empty output and the hooks fail open (never block).

read_hook_stdin() {
    local raw
    raw="$(cat 2>/dev/null)"
    raw="${raw#$'\xef\xbb\xbf'}"
    printf '%s' "$raw"
}

have_jq() { command -v jq >/dev/null 2>&1; }
have_py() { command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; }

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
    printf '{}'
}

safe_conversation_id() {
    local input="$1" cid
    cid="$(json_get "$input" conversation_id | tr -cd 'A-Za-z0-9_-')"
    # Fall back to transcript_path basename — unique per conversation, prevents
    # cross-session brake interference when conversation_id is absent.
    if [ -z "$cid" ]; then
        local tp
        tp="$(json_get "$input" transcript_path)"
        if [ -n "$tp" ]; then
            cid="$(basename "$tp" | sed 's/\.[^.]*$//' | tr -cd 'A-Za-z0-9_-')"
        fi
    fi
    printf '%s' "${cid:-default}"
}

# resolve_project_root <json> -> project root ('' if none resolves; NO $HOME
# fallback — final-review runs git against $root, so a $HOME fallback would
# silently turn the profile into the audited repo). Falls back to $PWD if it's
# a git repo, because Cursor's beforeSubmitPrompt event does NOT include cwd
# in its payload — the hook process's CWD is the project root in that case.
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
    # Fallback: $PWD (git repo guard — no ghost .scope.json in $HOME).
    if [ -z "$root" ]; then
        local pwd_fwd="${PWD%/}"
        if [ -n "$pwd_fwd" ] && git -C "$pwd_fwd" rev-parse --git-dir >/dev/null 2>&1; then
            root="$pwd_fwd"
        fi
    fi
    printf '%s' "$root"
}

expand_agent_paths() {
    local text="$1"
    local home="${HOME%/}"
    text="${text//\~\//$home/}"
    printf '%s' "$text"
}

resolve_agent_path() {
    local p="$1"
    case "$p" in
        "~/"*) printf '%s' "$HOME/${p#~/}" ;;
        *) printf '%s' "$p" ;;
    esac
}

# extract_last_user_query <json> -> text of the last *human* <user_query> in this
# conversation's transcript, or '' if there is none. Capped at 2000 chars.
# Walks the JSONL backward via tac (preferred) or awk fallback; finds the first
# (last) user record whose content carries a <user_query> tag, SKIPPING
# hook-generated turns so we return the human request, not the review boilerplate.
extract_last_user_query() {
    local json="$1"
    local tp
    tp="$(json_get "$json" transcript_path)"
    [ -n "$tp" ] && [ -f "$tp" ] || return 0

    local reversed
    if command -v tac >/dev/null 2>&1; then
        reversed="$(tac "$tp" 2>/dev/null)"
    else
        reversed="$(awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' "$tp" 2>/dev/null)"
    fi
    [ -n "$reversed" ] || return 0

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

    # No python3: best-effort grep, drop hook-generated turns.
    printf '%s' "$reversed" |
        grep -oE '<user_query>[^<]*</user_query>' 2>/dev/null |
        sed -E 's@</?user_query>@@g' |
        grep -vE '^[[:space:]]*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED)' 2>/dev/null |
        head -n1 |
        sed -E 's/\bnpm_[A-Za-z0-9]{10,}\b/[REDACTED_NPM_TOKEN]/g' |
        head -c 2000
}
