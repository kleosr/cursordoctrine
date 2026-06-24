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
    Write|StrReplace|ApplyPatch|Edit|MultiEdit) ;;
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

tool_input="$(json_get "$input" tool_input)"
[ -n "$tool_input" ] || allow

if have_py; then
    eval "$(printf '%s' "$tool_input" | python3 -c '
import json, sys, shlex
try:
    ti = json.load(sys.stdin)
except Exception:
  ti = {}
if not isinstance(ti, dict):
    ti = {}
path = ""
for k in ("path", "file_path", "filename", "absolute_path", "abs_path", "target_file"):
    v = ti.get(k)
    if v:
        path = str(v)
        break
print("target_path=" + shlex.quote(path))
' 2>/dev/null)"
else
    target_path="$(printf '%s' "$tool_input" | jq -r '
  .path // .file_path // .filename // .absolute_path // .abs_path // .target_file // empty
' 2>/dev/null)"
fi

[ -n "${target_path:-}" ] || allow

# Normalize to repo-relative path.
rel="${target_path//\\//}"
case "$rel" in
    "$root"/*) rel="${rel#"$root"/}" ;;
esac
rel="${rel#/}"
[ -n "$rel" ] || allow
[ "$rel" = ".scope.json" ] && allow

if have_jq; then
    intent="$(printf '%s' "$scope_raw" | jq -r '.intent // ""' 2>/dev/null)"
    real_files="$(printf '%s' "$scope_raw" | jq -r '
      [.files[]? | select(
        . != null and . != "" and
        (test("^\\s*<TODO") | not) and
        (. != ".scope.json")
      )] | length
    ' 2>/dev/null)"
    decomp_count="$(printf '%s' "$scope_raw" | jq -r '.decomposition // [] | length' 2>/dev/null)"
elif have_py; then
    read -r intent real_files decomp_count <<<"$(printf '%s' "$scope_raw" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception:
    print(" 0 0")
    raise SystemExit
intent = (o.get("intent") or "").strip()
files = o.get("files") or []
real = 0
for e in files:
    s = str(e or "").strip()
    if not s or s.startswith("<TODO") or s == ".scope.json":
        continue
    real += 1
decomp = len(o.get("decomposition") or [])
print(intent, real, decomp)
' 2>/dev/null)"
fi

intent="$(printf '%s' "${intent:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -z "$intent" ] || [ "$intent" = "[DRAFT]" ]; then
    deny "intent is empty — write your one-line Step 0 restatement to .scope.json before editing code."
fi

case "${real_files:-0}" in ''|*[!0-9]*) real_files=0 ;; esac
case "${decomp_count:-0}" in ''|*[!0-9]*) decomp_count=0 ;; esac

if [ "$real_files" -ge 1 ] && [ "$decomp_count" -eq 0 ]; then
    deny "files[] already has 1 entry and decomposition[] is empty — declare steps in .scope.json before editing another file."
fi

allow
