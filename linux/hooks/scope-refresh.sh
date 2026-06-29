#!/usr/bin/env bash
# scope-refresh.sh - afterFileEdit: record the edit into .scope.json files[], then stash for re-injection.
#
# Two jobs on every edit, both deterministic:
#   1. RECORD: append the edited file to .scope.json's files[] (dedup, preserve
#      order, never touch .scope.json itself). The agent is unreliable at
#      maintaining files[] by hand; this hook keeps it an accurate session
#      footprint without relying on the model. Other fields (intent, acceptance)
#      are preserved verbatim.
#   2. STASH: write a one-line reminder (intent / files / acceptance) to the
#      per-cid pending file. scope-drain.sh (postToolUse, fires next) delivers
#      it as additional_context. Per-edit re-injection against Salience
#      Dilution: keeps the contract visible as a turn fills with code.
#
# Cursor does not consume afterFileEdit output directly, which is why the
# stash-and-drain pair exists. Writing .scope.json via shell redirection is
# NOT a tool invocation, so it does not re-trigger afterFileEdit.
#
# One state file (scope-<cid>.txt), no hashes, no latches. Silent when no
# .scope.json exists (trivial edits, fresh repos). Disable: HOOKS_ENFORCE=0
# or SCOPE_REFRESH_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_REFRESH_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

cid="$(safe_conversation_id "$input")"
root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || exit 0

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || exit 0

edited_file=""
for k in file_path path filename absolute_path abs_path; do
    v="$(json_get "$input" "$k")"
    if [ -n "$v" ]; then edited_file="$v"; break; fi
done

if [ -n "$edited_file" ]; then
    rel="$(scope_relative_path "$edited_file" "$root")"
    if is_plan_artifact_path "$rel"; then
        exit 0
    fi

    if [ -n "$rel" ] && [ "$(printf '%s' "$rel" | tr 'A-Z' 'a-z')" != ".scope.json" ]; then
        if have_jq; then
            new_raw="$(printf '%s' "$scope_raw" | jq --arg f "$rel" '
                .files = (
                    ((.files // []) | map(select(type == "string" and . != "" and (test("^\\s*<TODO") | not) and ((. | ltrimstr("/") | ascii_downcase) != ".scope.json"))))
                    + ([(.files // []) | map(ltrimstr("/") | ascii_downcase) | index($f | ltrimstr("/") | ascii_downcase)] | map(select(. != null)) | length as $present
                       | if $present == 0 then [$f] else [] end)
                )' 2>/dev/null)"
            if [ -n "$new_raw" ] && [ "$new_raw" != "$scope_raw" ]; then
                printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
                scope_raw="$new_raw"
            fi
        elif have_py; then
            new_raw="$(printf '%s' "$scope_raw" | F="$rel" python3 -c '
import json, os, re, sys
try:
    o = json.load(sys.stdin)
    f = os.environ["F"]
    files = [x for x in (o.get("files") or []) if x and not re.match(r"\s*<TODO", str(x)) and str(x).strip().lstrip("/").lower() != ".scope.json"]
    norm = lambda s: s.replace("\\", "/").lstrip("/").lower()
    if norm(f) not in {norm(x) for x in files}:
        files.append(f)
    o["files"] = files
    print(json.dumps(o, indent=2, ensure_ascii=False))
except Exception:
    pass' 2>/dev/null)"
            if [ -n "$new_raw" ] && [ "$new_raw" != "$scope_raw" ]; then
                printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
                scope_raw="$new_raw"
            fi
        fi
    fi
fi

if have_jq; then
    user_prompt="$(printf '%s' "$scope_raw" | jq -r '.prompt // empty' 2>/dev/null)"
    intent="$(printf '%s' "$scope_raw" | jq -r '.intent // empty' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | jq -r '.acceptance // empty' 2>/dev/null)"
    files_list="$(printf '%s' "$scope_raw" | jq -r '.files // [] | join(", ")' 2>/dev/null)"
elif have_py; then
    user_prompt="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("prompt") or "")
except Exception: pass' 2>/dev/null)"
    intent="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("intent") or "")
except Exception: pass' 2>/dev/null)"
    acceptance="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("acceptance") or "")
except Exception: pass' 2>/dev/null)"
    files_list="$(printf '%s' "$scope_raw" | python3 -c 'import json,sys
try: print(", ".join(json.load(sys.stdin).get("files") or []))
except Exception: pass' 2>/dev/null)"
else
    exit 0
fi

[ -n "$files_list" ] || files_list="(none yet)"
[ -n "$intent" ] || intent="(not set yet — restate at Step 0)"

msg="SCOPE REMINDER (re-injected after your edit):
  prompt: $user_prompt
  intent: $intent
  files: $files_list"
[ -n "$acceptance" ] && msg="$msg
  acceptance: $acceptance"
msg="$msg

Confirm this edit advances intent. The file you just edited was recorded into files[]."

pending="$HOME/.cursor/.hooks-pending/scope-$cid.txt"
mkdir -p "$(dirname "$pending")" 2>/dev/null
printf '%s' "$msg" > "$pending" 2>/dev/null
exit 0
