#!/usr/bin/env bash
# hook-common.sh - shared helpers for Cursor agent hooks (Linux).
# Source from sibling scripts:  . "$(dirname "$0")/hook-common.sh"
#
# Shared by all hooks in this pack. JSON parsing prefers jq; falls back to
# python3. If neither exists every helper degrades to empty output and the
# hooks fail open (never block).

readonly DEFAULT_ACCEPTANCE='Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

read_hook_stdin() {
    local raw
    raw="$(cat 2>/dev/null)"
    raw="${raw#$'\xef\xbb\xbf'}"
    printf '%s' "$raw"
}

have_jq() { command -v jq >/dev/null 2>&1; }

__detect_python() {
    if command -v python3 >/dev/null 2>&1 && command python3 -c '' >/dev/null 2>&1; then
        PY=python3
        return
    fi
    if command -v python >/dev/null 2>&1 && command python -c '' >/dev/null 2>&1; then
        PY=python
        return
    fi
    PY=
}
__detect_python
have_py() { [ -n "${PY:-}" ]; }

# ponytail: Windows Git Bash ships a broken `python3` Store stub; shim it to
# `python` so the ~55 `python3` call sites work without editing each. Ceiling:
# single-process shim. Upgrade: install real python3 and drop this.
if [ "${PY:-}" = python ]; then
    python3() { command python "$@"; }
fi

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

# ponytail: dependency-free extraction of a top-level "key":"value" string
# field when neither jq nor python3 is present.
json_get_string_native() {
    local json="$1" key="$2"
    [ -n "$json" ] || return 0
    printf '%s' "$json" |
        sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"\\]*\(\\.[^\"\\]*\)*\)\".*/\1/p" |
        head -n1
}

# Atomic, crash-safe .scope.json write: mkdir lock (portable atomic primitive),
# write a temp file, mv -f over the target. Serializes the write only — callers
# that read-modify-write outside this lock can still lose updates.
# ponytail: lock ceiling = stale lockdir left by a hard-killed process is swept
# after 10s; not flock(2). Upgrade = flock where available.
write_scope_json_atomic() {
    local path="$1" content="$2"
    [ -n "$path" ] || return 0
    # Refuse empty content: an empty .scope.json is always a transform failure,
    # never a valid state. Guarding here makes truncation impossible even if a
    # caller forgets to check the transform output before writing.
    [ -n "$content" ] || return 0
    local dir
    dir="$(dirname "$path")"
    [ -n "$dir" ] || return 0
    local lock="$path.lock"
    if [ -d "$lock" ]; then
        local lock_mtime now age
        lock_mtime="$(date -r "$lock" +%s 2>/dev/null || echo 0)"
        now="$(date +%s 2>/dev/null || echo 0)"
        age=$(( now - lock_mtime ))
        [ "$age" -gt 10 ] 2>/dev/null && rm -rf "$lock" 2>/dev/null
    fi
    local acquired=false i=0
    while [ "$i" -lt 10 ]; do
        if mkdir "$lock" 2>/dev/null; then acquired=true; break; fi
        sleep 0.05 2>/dev/null || sleep 1
        i=$(( i + 1 ))
    done
    [ "$acquired" = true ] || return 0
    local tmp="$path.tmp.$$"
    if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null; rm -rf "$lock" 2>/dev/null; return 0
    fi
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    rm -rf "$lock" 2>/dev/null
}

read_scope_file_lines() {
    local path="$1"
    [ -f "$path" ] || return 0
    have_py || return 0
    SCOPE_PATH="$path" python3 -c '
import json, os
try:
    for f in (json.load(open(os.environ["SCOPE_PATH"])).get("files") or []):
        s = str(f).strip()
        if s and not s.startswith("<") and s != ".scope.json":
            print(s.replace("\\\\", "/").lstrip("/"))
except Exception: pass' 2>/dev/null
}

scope_json_string_field() {
    local raw="$1" field="$2"
    [ -n "$raw" ] || return 0
    have_py || return 0
    SCOPE_RAW="$raw" FIELD="$field" python3 -c '
import json, os
try:
    v = json.loads(os.environ["SCOPE_RAW"]).get(os.environ["FIELD"]) or ""
    if isinstance(v, str):
        print(v)
except Exception: pass' 2>/dev/null
}

read_nudge_flag() {
    local flag="$1" last_count=-1 nudge_count=0 parts
    if [ -f "$flag" ]; then
        IFS=':' read -r last_count nudge_count _ < "$flag" 2>/dev/null || true
        [ -z "$last_count" ] && last_count=-1
        [ -z "$nudge_count" ] && nudge_count=0
    fi
    printf '%s:%s' "$last_count" "$nudge_count"
}

write_nudge_flag() {
    local flag="$1" files_count="$2" nudge_count="$3" dir
    dir="$(dirname "$flag")"
    mkdir -p "$dir" 2>/dev/null
    printf '%s:%s' "$files_count" "$nudge_count" > "$flag" 2>/dev/null
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

session_stamp_path() {
    local input="$1" cid
    cid="$(safe_conversation_id "$input")"
    printf '%s' "$HOME/.cursor/.hooks-pending/session-start-${cid}.txt"
}

write_session_start_stamp() {
    local input="$1" path dir
    [ -n "$input" ] || return 0
    path="$(session_stamp_path "$input")"
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null
    date -u +%Y-%m-%dT%H:%M:%SZ > "$path" 2>/dev/null
}

ensure_session_start_stamp() {
    local input="$1" path
    path="$(session_stamp_path "$input")"
    [ -f "$path" ] || write_session_start_stamp "$input"
}

get_session_start_epoch() {
    local input="$1" path ts ep
    path="$(session_stamp_path "$input")"
    [ -f "$path" ] || return 1
    ts="$(cat "$path" 2>/dev/null | tr -d '\r\n')"
    [ -n "$ts" ] || return 1
    if have_py; then
        TS="$ts" python3 -c '
from datetime import datetime, timezone
import os, sys
raw = os.environ["TS"].replace("Z", "+00:00")
try:
    t = datetime.fromisoformat(raw)
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    ep = int(t.timestamp())
    if ep > 0:
        print(ep)
except Exception:
    sys.exit(1)' 2>/dev/null && return 0
    fi
    ep="$(date -d "$ts" +%s 2>/dev/null)"
    [ -n "$ep" ] && [ "$ep" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$ep"
}

path_modified_since_session() {
    local fullpath="$1" input="$2" session_epoch file_epoch
    session_epoch="$(get_session_start_epoch "$input")" || return 1
    [ -e "$fullpath" ] || return 1
    file_epoch="$(date -r "$fullpath" +%s 2>/dev/null || stat -c %Y "$fullpath" 2>/dev/null || echo 0)"
    [ "$file_epoch" -ge "$(( session_epoch - 1 ))" ] 2>/dev/null
}

# resolve_project_root <json> -> project root ('' if none resolves; NO $HOME
# fallback — final-review runs git against $root, so a $HOME fallback would
# silently turn the profile into the audited repo). Falls back to $PWD if it
# looks like a project root, because Cursor's beforeSubmitPrompt event does
# NOT include cwd in its payload — the hook process's CWD is the project root
# in that case. Any git repo OR any dir with a recognized project marker file
# is accepted, so this works for non-git repos too.
is_project_root() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    local markers=(
        .git .hg .svn package.json Cargo.toml go.mod pyproject.toml setup.py
        pom.xml build.gradle build.gradle.kts Gemfile composer.json
        Makefile CMakeLists.txt .project tsconfig.json
    )
    for m in "${markers[@]}"; do
        [ -e "$dir/$m" ] && return 0
    done
    return 1
}
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
    # Fallback: $PWD (project-marker guard — no ghost .scope.json in $HOME).
    if [ -z "$root" ]; then
        local pwd_fwd="${PWD%/}"
        if [ -n "$pwd_fwd" ] && is_project_root "$pwd_fwd"; then
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

scope_relative_path() {
    local p="$1" root="$2"
    [ -n "$p" ] && [ -n "$root" ] || return 0
    p="$(printf '%s' "$p" | tr '\\' '/')"
    root="$(printf '%s' "$root" | tr '\\' '/' | sed 's|/*$||')"
    case "$p" in
        [A-Za-z]:/*)
            # Windows drive-absolute paths live on a case-insensitive filesystem,
            # so match the root prefix case-insensitively (parity with the PS
            # twin's OrdIgnoreCase). Strip by length to preserve the relative
            # part's original casing.
            local p_lc root_lc rootlen
            p_lc="$(printf '%s' "$p" | tr 'A-Z' 'a-z')"
            root_lc="$(printf '%s' "$root" | tr 'A-Z' 'a-z')"
            rootlen="${#root_lc}"
            if [ "$p_lc" = "$root_lc" ]; then p=""
            elif [ "${p_lc:0:$((rootlen+1))}" = "$root_lc/" ]; then p="${p:$((rootlen+1))}"
            else return 0; fi
            ;;
        /*)
            case "$p" in
                "$root"/*) p="${p#"$root"/}" ;;
                *) return 0 ;;
            esac
            ;;
    esac
    local out="" part
    IFS='/' read -r -a _scope_parts <<< "$p"
    for part in "${_scope_parts[@]}"; do
        [ -n "$part" ] || continue
        [ "$part" = "." ] && continue
        [ "$part" = ".." ] && return 0
        if [ -n "$out" ]; then out="$out/$part"; else out="$part"; fi
    done
    printf '%s' "$out"
}

scope_relative_any_root() {
    local p="$1" input="$2" root w
    p="$(printf '%s' "$p")"
    input="$(printf '%s' "$input")"
    w="$(json_get "$input" cwd)"
    if [ -n "$w" ]; then
        root="$(printf '%s' "$w" | tr '\\' '/' | sed 's|/*$||')"
        if [ -n "$(scope_relative_path "$p" "$root")" ]; then
            scope_relative_path "$p" "$root"
            return 0
        fi
    fi
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        root="$(printf '%s' "$w" | tr '\\' '/' | sed 's|/*$||')"
        if [ -n "$(scope_relative_path "$p" "$root")" ]; then
            scope_relative_path "$p" "$root"
            return 0
        fi
    done <<EOF
$(json_get_array "$input" workspace_roots)
EOF
    root="$(resolve_project_root "$input")"
    [ -n "$root" ] && scope_relative_path "$p" "$root"
}

redact_secrets_from_intent() {
    local text="$1"
    [ -n "$text" ] || return 0
    if have_py; then
        T="$text" python3 -c '
import os, re
t = os.environ["T"]
t = re.sub(r"\bnpm_[A-Za-z0-9]{10,}\b", "[REDACTED_NPM_TOKEN]", t)
t = re.sub(r"\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b", "[REDACTED_TOKEN]", t)
t = re.sub(r"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+", r"\1=[REDACTED]", t)
print(t)' 2>/dev/null
        return
    fi
    printf '%s' "$text" | sed -E \
        -e 's/\bnpm_[A-Za-z0-9]{10,}\b/[REDACTED_NPM_TOKEN]/g' \
        -e 's/\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b/[REDACTED_TOKEN]/g' \
        -e 's/(api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/Ig'
}

is_plan_artifact_path() {
    local p="$1"
    [ -n "$p" ] || return 1
    p="$(printf '%s' "$p" | tr '\\' '/' | sed 's|^/*||')"
    case "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" in
        .cursor/plans|.cursor/plans/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_plan_mode_event() {
    local input="$1" k v
    for k in composer_mode composerMode agent_mode agentMode cursor_mode cursorMode chat_mode chatMode mode; do
        v="$(json_get "$input" "$k" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$v" in plan|planning|plan_mode|planning_mode) return 0 ;; esac
    done
    for k in is_plan_mode isPlanMode planning; do
        v="$(json_get "$input" "$k" | tr '[:upper:]' '[:lower:]')"
        case "$v" in true|1|yes) return 0 ;; esac
    done
    return 1
}

is_plan_only_prompt() {
    local text="$1" lc
    [ -n "$text" ] || return 1
    lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
    # POSIX-portable word matching: `grep -Ew` and explicit [^[:alnum:]_]
    # boundaries instead of GNU \b (absent on BSD/macOS grep, where it
    # silently fails to match and plan detection breaks).
    printf '%s' "$lc" | grep -Ewq 'implement|build|fix|edit|modify|change|patch|apply|code|ship|execute|wire|refactor|update|make this work|do it' && return 1
    printf '%s' "$lc" | grep -Eq '<proposed_plan>' && return 0
    printf '%s' "$lc" | grep -Ewq 'plan mode|planning mode' && return 0
    printf '%s' "$lc" | grep -Eq '(^|[^[:alnum:]_])(write|draft|propose|produce|generate|outline|create|make)([^[:alnum:]_]|$).{0,80}(^|[^[:alnum:]_])(plan|implementation plan|spec)([^[:alnum:]_]|$)' && return 0
    printf '%s' "$lc" | grep -Eq '(^|[^[:alnum:]_])(plan|spec)([^[:alnum:]_]|$).{0,80}(^|[^[:alnum:]_])(only|first|before implementation|before coding)([^[:alnum:]_]|$)' && return 0
    return 1
}

final_review_debug() {
    [ "${FINAL_REVIEW_DEBUG:-}" = "1" ] || return 0
    local reason="$1"
    [ -n "$reason" ] || return 0
    mkdir -p "$HOME/.cursor/.hooks-pending" 2>/dev/null
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')" "$reason" \
        >>"$HOME/.cursor/.hooks-pending/last-final-review.log" 2>/dev/null
}

# extract_last_raw_user_query <json> -> last <user_query> text (hook turns included)
extract_last_raw_user_query() {
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
        if m:
            print(m.group(1).strip())
            break
except Exception:
    pass
' 2>/dev/null
        return 0
    fi

    printf '%s' "$reversed" |
        grep -oE '<user_query>[^<]*</user_query>' 2>/dev/null |
        sed -E 's@</?user_query>@@g' |
        head -n1
}

is_hook_generated_query() {
    local text="$1"
    [ -n "$text" ] || return 1
    printf '%s' "$text" | grep -qE '^[[:space:]]*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER|VERIFY MILESTONE)'
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
HOOK_HDR = re.compile(r"^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER|VERIFY MILESTONE)", re.M)
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
    # Portable [^[:alnum:]_] boundaries (not GNU \b) + full token set matching
    # the python redaction path above (sk-/ghp_/gho_/key=value were missing,
    # leaking secrets when python3 was absent).
    printf '%s' "$reversed" |
        grep -oE '<user_query>[^<]*</user_query>' 2>/dev/null |
        sed -E 's@</?user_query>@@g' |
        grep -vE '^[[:space:]]*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER|VERIFY MILESTONE)' 2>/dev/null |
        head -n1 |
        sed -E 's/(^|[^[:alnum:]_])npm_[A-Za-z0-9]{10,}([^[:alnum:]_]|$)/\1[REDACTED_NPM_TOKEN]\2/g' |
        sed -E 's/(^|[^[:alnum:]_])(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})([^[:alnum:]_]|$)/\1[REDACTED_TOKEN]\3/g' |
        sed -E 's/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g' |
        head -c 2000
}
