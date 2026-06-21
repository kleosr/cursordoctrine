#!/usr/bin/env bash
# permission-gate.sh - beforeShellExecution for Cursor (Linux).
#
# Single responsibility: deny a small, explicit list of dangerous commands.
# This is a *permission* gate, not a *quality* gate. The model handles
# quality; the harness handles blast radius.
#
# Behavior:
#   - Exit 0 always.
#   - Print Cursor-canonical {"permission": "allow"|"deny", ...} JSON.
#   - On internal failure: fail OPEN (allow), never block the user.
#
# Disable: PERM_GATE_ENFORCE=0

set +e
. "$(dirname "$0")/hook-common.sh"

allow() { printf '{"permission":"allow"}'; exit 0; }

[ "${PERM_GATE_ENFORCE:-}" = "0" ] && allow

input="$(read_hook_stdin)"
cmd="$(json_get "$input" command)"
# Belt-and-braces: if stdin was not the documented JSON shape, still gate
# on the raw text rather than waving everything through.
[ -n "$cmd" ] || cmd="$input"
[ -n "$cmd" ] || allow

deny() {
    local reason="$1" shown="$cmd"
    # Truncate the echo: the UI message only needs enough to identify it.
    [ "${#shown}" -gt 400 ] && shown="${shown:0:400}..."
    local user_msg="BLOCKED by permission-gate: $reason

Command: $shown

If this is genuinely intended, run it yourself in your terminal."
    if have_jq; then
        jq -cna --arg u "$user_msg" \
            '{permission:"deny", user_message:$u, agent_message:($u + " Do not retry verbatim. Ask the user to run it manually if it is truly intended.")}'
    elif have_py; then
        U="$user_msg" python3 -c '
import json, os
u = os.environ["U"]
print(json.dumps({"permission": "deny", "user_message": u,
                  "agent_message": u + " Do not retry verbatim. Ask the user to run it manually if it is truly intended."},
                 ensure_ascii=True, separators=(",", ":")))'
    else
        printf '{"permission":"deny"}'
    fi
    exit 0
}

# test_deny <ERE pattern> <reason>
test_deny() {
    if printf '%s' "$cmd" | grep -qE "$1"; then deny "$2"; fi
}

# Anchored to start OR a command separator so `cd /tmp && rm -rf /` is caught,
# while `git rm`, `npm run rm-cache`, `echo "rm -rf /"` stay allowed.
test_deny '(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*([rR][fF]|[fF][rR])[a-zA-Z]*[[:space:]]+/' 'destructive rm -rf on absolute path (use relative paths or be more specific)'
test_deny ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:' 'fork-bomb pattern'
test_deny '(^|[;&|][[:space:]]*)bash[[:space:]]+-c[[:space:]]+[''"]?[[:space:]]*:[[:space:]]*\(\)[[:space:]]*\{' 'fork-bomb pattern via bash -c'
test_deny 'curl[[:space:]].*\|[[:space:]]*(sudo[[:space:]]*)?(bash|sh|zsh|dash|ash)' 'curl piped to shell'
test_deny 'wget[[:space:]].*\|[[:space:]]*(sudo[[:space:]]*)?(bash|sh|zsh|dash|ash)' 'wget piped to shell'
test_deny 'git[[:space:]]+push[[:space:]]+.*--force(-with-lease)?([[:space:]"'"'"']|$)' 'git push --force'
test_deny 'git[[:space:]]+push[[:space:]]+(-f|--force)([[:space:]"'"'"']|$)' 'git push -f / --force'
test_deny 'git[[:space:]]+reset[[:space:]]+--hard' 'git reset --hard (data loss)'
test_deny 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f' 'git clean -f (untracked data loss)'
test_deny 'dd[[:space:]].*of=/dev/(sd|nvme|hd|xvd)' 'dd to block device'
test_deny 'mkfs(\.[a-z0-9]+)?[[:space:]]+/dev/' 'mkfs on device'
test_deny 'chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/' 'chmod -R 777 on root'
test_deny 'chown[[:space:]]+-R[[:space:]]+[^[:space:]]+[[:space:]]+/' 'chown -R on root'
test_deny '^(npm|pnpm|yarn)[[:space:]]+publish([[:space:]]|$)' 'package publish (use ship-hook, not direct publish)'

allow
