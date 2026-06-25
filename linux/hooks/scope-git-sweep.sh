#!/usr/bin/env bash
# scope-git-sweep.sh - postToolUse: catch Shell-written files into .scope.json files[].
#
# Bash twin of scope-git-sweep.ps1. See that file for the full rationale:
# scope-refresh (afterFileEdit) misses files written through the Shell tool
# (heredocs, redirections, git apply, build outputs), so files[] under-counts
# and milestone-verify stays silent (its gate is files.Count -eq 0). This hook
# runs `git diff --name-only HEAD` + untracked after every Shell-tool postToolUse
# and unions new paths into files[].
#
# Silent on: kill switch, file-edit tool (afterFileEdit already recorded), no
# .scope.json, no git, no diff. Never emits additional_context — only maintains
# files[]. Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_REFRESH_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# Skip file-edit tools — afterFileEdit already recorded them. Run only after
# known shell-like tools so pre-existing dirty files are not attributed to
# read/search/tooling events.
tool_name="$(json_get "$input" tool_name)"
[ -z "$tool_name" ] && tool_name="$(json_get "$input" name)"
case "$tool_name" in
    Edit|Replace|Write|MultiEdit|editFile|file:edit|ApplyPatch|insert|str_replace|write|edit) exit 0 ;;
    Shell|Bash|Execute|shell|bash|RunCommand|run|terminal|cmd|powershell) ;;
    *) exit 0 ;;
esac

root="$(resolve_project_root "$input")"
[ -n "$root" ] || exit 0

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || exit 0

git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || exit 0

# Prefer python3 (matches the other Linux hooks' preferred path); fall back to jq.
if have_py; then
    diff_out="$(git -C "$root" diff --name-only HEAD 2>/dev/null; git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"
    [ -n "$diff_out" ] || exit 0
    new_raw="$(SCOPE_RAW="$scope_raw" SCOPE_PATH="$scope_path" DIFF_OUT="$diff_out" python3 -c '
import json, os, sys
try:
    scope = json.loads(os.environ["SCOPE_RAW"])
except Exception:
    sys.exit(0)
existing = scope.get("files") or []
# Prune placeholders/blanks/.scope.json — same filter as scope-refresh.
kept = []
for e in existing:
    s = str(e)
    if not s or not s.strip() or s.strip().startswith("<") or s.strip().lstrip("/").lower() == ".scope.json":
        continue
    kept.append(s)
kept_lc = set(s.replace("\\", "/").lstrip("/").lower() for s in kept)
appended = False
for line in os.environ["DIFF_OUT"].splitlines():
    parts = []
    for part in line.replace("\\", "/").split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            parts = []
            break
        parts.append(part)
    rel = "/".join(parts)
    if not rel or rel.lower() == ".scope.json":
        continue
    if rel.lower() in kept_lc:
        continue
    kept.append(rel)
    kept_lc.add(rel.lower())
    appended = True
if not appended:
    sys.exit(0)
scope["files"] = kept
try:
    with open(os.environ["SCOPE_PATH"], "w", encoding="utf-8") as fh:
        json.dump(scope, fh, indent=2, ensure_ascii=False)
except Exception:
    pass
' 2>/dev/null)"
    exit 0
fi

# jq fallback (no python3). Union diff paths into files[], same prune filter.
have_jq || exit 0
diff_out="$(git -C "$root" diff --name-only HEAD 2>/dev/null; git -C "$root" ls-files --others --exclude-standard 2>/dev/null)"
[ -n "$diff_out" ] || exit 0

new_raw="$(printf '%s' "$scope_raw" | jq --rawfile diff <(printf '%s\n' "$diff_out") '
    (.files // []) as $existing |
    ($existing | map(select(. != "" and (test("^\\s*<") | not) and ((. | ltrimstr("/") | ascii_downcase) != ".scope.json")))) as $kept |
    ($kept | map((. | gsub("\\\\"; "/") | ltrimstr("/") | ascii_downcase))) as $kept_lc |
    ($diff | split("\n") | map(gsub("\\\\"; "/") | ltrimstr("/") | select(. != "" and (ascii_downcase != ".scope.json") and (startswith("../") | not)))) as $diff_clean |
    (reduce $diff_clean[] as $p ($kept;
        . as $acc |
        ($acc | map(gsub("\\\\"; "/") | ltrimstr("/") | ascii_downcase) | index($p | ascii_downcase)) as $hit |
        if $hit then . else . + [$p] end
    )) as $union |
    if ($union | length) > ($existing | length) then .files = $union else empty end
' 2>/dev/null)"
[ -n "$new_raw" ] || exit 0
printf '%s' "$new_raw" > "$scope_path" 2>/dev/null
exit 0
