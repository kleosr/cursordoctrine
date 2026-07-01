#!/usr/bin/env bash
# step0-gate.sh - preToolUse: hard Step 0 gate for file-write tools (Linux).
#
# Narrow enforcement (second hard lever beside permission-gate):
#   - Always allow writes to .scope.json.
#   - Deny other file writes when intent is empty or still [DRAFT].
#   - Deny when files[] already has >=1 real entry and decomposition[] is empty.
#
# Read/Grep/Shell untouched. No .scope.json -> fail open. Internal errors -> fail open.
# Disable: STEP0_GATE_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

allow() { printf '{"permission":"allow"}'; exit 0; }

deny() {
    local reason="$1"
    local user_msg="BLOCKED by step0-gate: $reason

Write intent (+ decomposition[] for multi-file tasks) to .scope.json first, then retry."
    if have_jq; then
        jq -cna --arg u "$user_msg" \
            '{permission:"deny", user_message:$u, agent_message:($u + " Do not skip Step 0 — persist the contract to .scope.json, not chat prose.")}'
    elif have_py; then
        U="$user_msg" python3 -c '
import json, os
u = os.environ["U"]
print(json.dumps({"permission": "deny", "user_message": u,
                  "agent_message": u + " Do not skip Step 0 — persist the contract to .scope.json, not chat prose."},
                 ensure_ascii=True, separators=(",", ":")))'
    else
        printf '{"permission":"deny"}'
    fi
    exit 0
}

[ "${HOOKS_ENFORCE:-}" = "0" ] && allow
[ "${STEP0_GATE_ENFORCE:-}" = "0" ] && allow

input="$(read_hook_stdin)"
[ -n "$input" ] || allow

tool_name="$(json_get "$input" tool_name)"
case "$tool_name" in
    Write|StrReplace|ApplyPatch|Edit|MultiEdit|Replace) ;;
    '') ;;
    *) allow ;;
esac

root="$(resolve_project_root "$input")"
[ -n "$root" ] || allow

scope_path="$root/.scope.json"
[ -f "$scope_path" ] || allow

scope_raw="$(cat "$scope_path" 2>/dev/null)"
[ -n "$scope_raw" ] || allow

if ! have_jq && ! have_py; then allow; fi

if have_jq; then
    intent="$(printf '%s' "$scope_raw" | jq -r '.intent // ""' 2>/dev/null)"
    real_files="$(printf '%s' "$scope_raw" | jq -r '
      [.files[]? | select(
        . != null and . != "" and
        (test("^\\s*<TODO") | not) and
        (. != ".scope.json")
      )] | length
    ' 2>/dev/null)"
    decomp_count="$(printf '%s' "$scope_raw" | jq -r '
      [.decomposition[]? |
        ((.subtask // (. | tostring)) | tostring) as $s |
        select(($s | test("^\\s*$") | not) and ($s | test("^\\s*<TODO") | not))
      ] | length
    ' 2>/dev/null)"
elif have_py; then
    _gate_vals="$(printf '%s' "$scope_raw" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception:
    print(json.dumps(["", 0, 0]))
    raise SystemExit
intent = (o.get("intent") or "").strip()
files = o.get("files") or []
real = 0
for e in files:
    s = str(e or "").strip()
    if not s or s.startswith("<TODO") or s == ".scope.json":
        continue
    real += 1
decomp = 0
for d in (o.get("decomposition") or []):
    sub = d if isinstance(d, str) else (d.get("subtask") if isinstance(d, dict) else None)
    sub = str(sub or "").strip()
    if sub and not sub.startswith("<TODO"):
        decomp += 1
print(json.dumps([intent, real, decomp]))
' 2>/dev/null)"
    intent="$(printf '%s' "$_gate_vals" | python3 -c 'import json,sys; print((json.load(sys.stdin)+[""])[0])' 2>/dev/null)"
    real_files="$(printf '%s' "$_gate_vals" | python3 -c 'import json,sys; print((json.load(sys.stdin)+[0,0])[1])' 2>/dev/null)"
    decomp_count="$(printf '%s' "$_gate_vals" | python3 -c 'import json,sys; print((json.load(sys.stdin)+[0,0,0])[2])' 2>/dev/null)"
fi

# Normalized lowercased files[] list for the "second DISTINCT file" check
# (bug fix: re-editing the same file must not be blocked).
files_list_lc=""
if have_jq; then
    files_list_lc="$(printf '%s' "$scope_raw" | jq -r '.files[]? // empty | (. | tostring | gsub("\\\\"; "/") | ltrimstr("/") | ascii_downcase)' 2>/dev/null)"
elif have_py; then
    files_list_lc="$(printf '%s' "$scope_raw" | python3 -c '
import json, sys
try: o = json.load(sys.stdin)
except Exception: sys.exit(0)
for f in (o.get("files") or []):
    s = str(f).replace("\\","/").lstrip("/").lower()
    if s: print(s)
' 2>/dev/null)"
fi

intent="$(printf '%s' "${intent:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
intent_empty=false
case "$intent" in ''|'[DRAFT]'|'[DRAFT]'*) intent_empty=true ;; esac
case "${real_files:-0}" in ''|*[!0-9]*) real_files=0 ;; esac
case "${decomp_count:-0}" in ''|*[!0-9]*) decomp_count=0 ;; esac

tool_input="$(json_get "$input" tool_input)"
# Do NOT allow on empty tool_input: fall through to the no-paths branch, which
# denies when intent is empty. A bad/absent tool_input must not bypass Step 0.

if have_py; then
    target_paths="$(printf '%s' "$tool_input" | python3 -c '
import json, sys
try:
    ti = json.load(sys.stdin)
except Exception:
  ti = {}
if not isinstance(ti, dict):
    ti = {}
paths = []
for k in ("path", "file_path", "filename", "absolute_path", "abs_path", "target_file"):
    v = ti.get(k)
    if v:
        paths.append(str(v))
for e in ti.get("edits") or []:
    if not isinstance(e, dict):
        continue
    for k in ("path", "file_path", "filename", "absolute_path", "abs_path", "target_file"):
        v = e.get(k)
        if v:
            paths.append(str(v))
            break
print("\n".join(paths))
' 2>/dev/null)"
else
    target_paths="$(printf '%s' "$tool_input" | jq -r '
      [
        (.path // .file_path // .filename // .absolute_path // .abs_path // .target_file // empty),
        (.edits[]? | .path // .file_path // .filename // .absolute_path // .abs_path // .target_file // empty)
      ][] | select(. != "")
' 2>/dev/null)"
fi

if [ -z "${target_paths:-}" ]; then
    [ "$intent_empty" = true ] && deny "edit tool target path could not be parsed and intent is empty — fill .scope.json before editing."
    [ "$real_files" -ge 1 ] && [ "$decomp_count" -eq 0 ] && deny "edit tool target path could not be parsed and decomposition[] is empty after prior file edits."
    allow
fi

while IFS= read -r target_path; do
    [ -n "$target_path" ] || continue
    rel="$(scope_relative_path "$target_path" "$root")"
    [ -n "$rel" ] || deny "edit target is outside the resolved project root or could not be normalized."
    [ "$rel" = ".scope.json" ] && continue
    [ "$intent_empty" = true ] && deny "intent is empty — write your one-line Step 0 restatement to .scope.json before editing code."
    rel_lc="$(printf '%s' "$rel" | tr 'A-Z' 'a-z')"
    already=false
    if [ -n "$files_list_lc" ] && printf '%s\n' "$files_list_lc" | grep -qxF "$rel_lc"; then already=true; fi
    [ "$already" = false ] && [ "$real_files" -ge 1 ] && [ "$decomp_count" -eq 0 ] && deny "about to edit a second distinct file and decomposition[] is empty — declare steps in .scope.json before editing another file."
done <<EOF
$target_paths
EOF

allow
