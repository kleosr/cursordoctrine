#!/usr/bin/env bash
# minimal-edit-audit.sh - afterFileEdit minimal-editing advisory (Cursor, Linux).
#
# Audits the just-edited file for over-editing:
#   * line-count    - git diff --numstat thresholds (any language).
#   * token metrics - audit-metrics.py (token-Levenshtein + cognitive
#                     complexity), Python files only, if the script exists.
# On WARN/FAIL it APPENDS a short advisory to the shared pending-feedback file;
# post-tool-use.sh delivers it as additional_context on the next tool turn.
#
# Advisory only: never blocks, never writes persistent state. afterFileEdit
# output isn't consumed and a non-zero exit shows as "hook failed", so we
# ALWAYS exit 0.
#
# Thresholds (env-overridable): MINIMAL_EDIT_FAIL_LINES (400), MINIMAL_EDIT_WARN_LINES (100).
# Disable: HOOKS_ENFORCE=0  or  MINIMAL_EDITING_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${MINIMAL_EDITING_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# audit root = project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
root=""
while IFS= read -r cand; do
    [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
[ -n "$root" ] || root="${CURSOR_PROJECT_DIR:-$HOME}"
root="${root%/}"

# edited file -> repo-relative path
fp=""
for k in file_path path filename absolute_path abs_path; do
    fp="$(json_get "$input" "$k")"
    [ -n "$fp" ] && break
done
[ -n "$fp" ] || exit 0
rel="$fp"
case "$rel" in "$root"/*) rel="${rel#"$root"/}" ;; esac
if is_cursor_config_path "$fp" || is_cursor_config_path "$rel"; then exit 0; fi

# git repo?
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# --- line-count audit (any language) --------------------------------------
fail_lines="${MINIMAL_EDIT_FAIL_LINES:-400}"
warn_lines="${MINIMAL_EDIT_WARN_LINES:-100}"
changed="$(git -C "$root" diff HEAD --numstat -- "$rel" 2>/dev/null |
    awk '$1 != "-" && $2 != "-" { n += $1 + $2 } END { print n + 0 }')"

grade="OK"; hint=""
if [ "$changed" -gt "$fail_lines" ]; then
    grade="FAIL"; hint="$changed lines changed (limit $fail_lines) - likely over-editing; trim or split"
elif [ "$changed" -gt "$warn_lines" ]; then
    grade="WARN"; hint="$changed lines changed - justify each hunk or split the task"
fi

# --- token metrics (.py only) ---------------------------------------------
audit_metrics="$HOME/.cursor/skills/minimal-editing/scripts/audit-metrics.py"
if [ -f "$audit_metrics" ] && have_py; then
    case "$rel" in
    *.py)
        mgrade="$(python3 "$audit_metrics" --root "$root" --format json --path "$rel" 2>/dev/null |
            { if have_jq; then jq -r '.grade // empty'; else python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("grade",""))
except Exception: pass'; fi; })"
        if [ "$mgrade" = "FAIL" ]; then grade="FAIL"
        elif [ "$mgrade" = "WARN" ] && [ "$grade" = "OK" ]; then grade="WARN"; fi
        ;;
    esac
fi

[ "$grade" = "OK" ] && exit 0

# --- compose advisory + append to the shared pending file ------------------
hint_txt=""
[ -n "$hint" ] && hint_txt=" - $hint"
if [ "$grade" = "FAIL" ]; then
    actions="  - Trim every hunk that isn't required by the task.
  - Prefer narrow, targeted edits over rewriting blocks.
  - If the change is genuinely large, split it into smaller logical commits."
else
    actions="  Advisory only - trim unrelated hunks if any; otherwise proceed."
fi

msg="Minimal-edit audit $grade - $rel

IMPORTANT: Try to preserve the original code and the logic of the original code as much as possible.

grade: $grade$hint_txt

$actions

(Disable for this session: HOOKS_ENFORCE=0)"

cid="$(safe_conversation_id "$input")"
pending="$(hooks_pending_dir)/feedback-$cid.txt"
mkdir -p "$(dirname "$pending")" 2>/dev/null
if [ -s "$pending" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending" 2>/dev/null
fi

exit 0
