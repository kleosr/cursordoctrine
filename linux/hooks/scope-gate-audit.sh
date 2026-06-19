#!/usr/bin/env bash
# scope-gate-audit.sh - afterFileEdit "scope auto-record" (Cursor, Linux).
#
# Compuerta 1, mechanical edition: keep .scope.json's files[] in sync with what
# the agent ACTUALLY edits, with ZERO reliance on the model remembering to fill
# it. intent-anchor.sh writes the scaffold (intent locked from the prompt,
# files: [], acceptance: TODO); THIS hook appends every edited file to files[]
# as the edit happens. Net effect: the contract's files[] is always an accurate
# ledger of the session footprint, which final-review audits against intent.
#
# This REPLACES the old declared-scope VIOLATION advisory. When every edit is
# auto-recorded, an edit can never be "out of declared scope" - there is nothing
# to violate. The gate became a recorder. acceptance stays the model's to fill.
#
# Opt-in: silent if .scope.json does not exist in the repo root. Rewrites ONLY
# files[]; every other field is preserved. jq preferred, python3 fallback; if
# neither is present we fail open (no JSON tool = no record). ALWAYS exits 0.
# Disable: HOOKS_ENFORCE=0  or  SCOPE_GATE_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${SCOPE_GATE_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# audit root: project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
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
rel="${rel#/}"
if is_cursor_config_path "$fp" || is_cursor_config_path "$rel"; then exit 0; fi
# Never record the contract file into itself.
[ "$rel" = ".scope.json" ] && exit 0

# --- opt-in gate: no .scope.json = nothing to maintain ---------------------
scope_file="$root/.scope.json"
[ -f "$scope_file" ] || exit 0

# --- auto-record $rel into files[] (jq preferred, python3 fallback) --------
# Clean the existing list (drop the scaffold placeholder + blanks), then add
# this edit if absent. Write only when the resulting files[] actually changed,
# so repeat edits of the same file do not churn the contract.
jq_prog='((.files // []) | map(select(type=="string" and . != "" and (startswith("<TODO")|not)))) as $c'

if have_jq; then
    old_files="$(jq -c '.files // []' "$scope_file" 2>/dev/null)"
    new_files="$(jq -c --arg rel "$rel" "$jq_prog | (if (\$c | index(\$rel)) then \$c else \$c + [\$rel] end)" "$scope_file" 2>/dev/null)"
    [ -n "$new_files" ] || exit 0
    [ "$new_files" = "$old_files" ] && exit 0
    updated="$(jq --arg rel "$rel" "$jq_prog | .files = (if (\$c | index(\$rel)) then \$c else \$c + [\$rel] end)" "$scope_file" 2>/dev/null)"
    [ -n "$updated" ] && printf '%s\n' "$updated" > "$scope_file"
elif have_py; then
    I_FILE="$scope_file" I_REL="$rel" python3 -c '
import json, os, sys
path = os.environ["I_FILE"]; rel = os.environ["I_REL"]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
files = d.get("files", []) or []
clean = [f for f in files if isinstance(f, str) and f and not f.startswith("<TODO")]
new = clean if rel in clean else clean + [rel]
if new == files:
    sys.exit(0)
d["files"] = new
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
' 2>/dev/null
fi

exit 0
