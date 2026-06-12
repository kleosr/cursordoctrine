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

hooks_pending_dir() { printf '%s' "$HOME/.cursor/.hooks-pending"; }

# is_cursor_config_path <path> -> 0 if the path lives under a .cursor directory
is_cursor_config_path() {
    case "$1" in
        */.cursor/*|*/.cursor|.cursor/*|.cursor) return 0 ;;
        *) return 1 ;;
    esac
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
