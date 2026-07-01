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

[ "${HOOKS_ENFORCE:-}" = "0" ] && allow
[ "${PERM_GATE_ENFORCE:-}" = "0" ] && allow

input="$(read_hook_stdin)"
cmd="$(json_get "$input" command)"
# Dependency-free fallback so the gate never goes blind when neither jq nor
# python3 is installed (json_get returns empty then); without it the anchored
# rules see the raw JSON envelope and miss `rm -rf /` / `npm publish`.
[ -n "$cmd" ] || cmd="$(json_get_string_native "$input" command)"
if [ -z "$cmd" ] && [ -n "$input" ]; then
    case "$input" in
        \{*) ;;
        *) cmd="$(printf '%s' "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ;;
    esac
fi
[ -n "$cmd" ] || allow

deny() {
    local reason="$1" shown="$cmd"
    [ "${#shown}" -gt 400 ] && shown="${shown:0:400}..."
    shown="$(redact_secrets_from_intent "$shown")"
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
# while `git rm`, `npm run rm-cache`, `echo "rm -rf /"` stay allowed. Quote-
# tolerant path (`rm -rf "/"`) so quoting the argument no longer bypasses.
_cmd_anchor='(^|[;&|][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*'
_rm_dest='['"'"'"]?(/|~(/|['"'"'"]|[[:space:]]|$))'
test_deny "${_cmd_anchor}(sudo[[:space:]]+)?rm[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*([rR][fF]|[fF][rR])[a-zA-Z]*([[:space:]]+--[^[:space:]]*)*[[:space:]]+${_rm_dest}" 'destructive rm -rf on absolute or home path (use relative paths or be more specific)'
test_deny "${_cmd_anchor}(sudo[[:space:]]+)?rm[[:space:]]+[^;&|]*-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+[^;&|]*-[a-zA-Z]*[fF][a-zA-Z]*[^;&|]*[[:space:]]+${_rm_dest}" 'destructive rm -rf on absolute or home path (separate -r/-f flags)'
test_deny "${_cmd_anchor}(sudo[[:space:]]+)?rm[[:space:]]+[^;&|]*-[a-zA-Z]*[fF][a-zA-Z]*[[:space:]]+[^;&|]*-[a-zA-Z]*[rR][a-zA-Z]*[^;&|]*[[:space:]]+${_rm_dest}" 'destructive rm -rf on absolute or home path (separate -f/-r flags)'
test_deny ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:' 'fork-bomb pattern'
test_deny '(^|[;&|][[:space:]]*)bash[[:space:]]+-c[[:space:]]+[''"]?[[:space:]]*:[[:space:]]*\(\)[[:space:]]*\{' 'fork-bomb pattern via bash -c'
# sudo may carry flags between sudo and the shell (`sudo -E bash`); tolerate
# them so the rule is not defeated by a single intervening flag.
test_deny 'curl[[:space:]].*\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?(bash|sh|zsh|dash|ash)' 'curl piped to shell'
test_deny 'wget[[:space:]].*\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?(bash|sh|zsh|dash|ash)' 'wget piped to shell'
# Process substitution is the no-`|` twin of curl|sh; same threat model.
test_deny '<\([[:space:]]*(curl|wget)[[:space:]]' 'curl/wget via process substitution piped to shell'
# --force-with-lease is the SAFE variant (aborts if remote moved); allow it so
# users aren't pushed toward the dangerous bare --force. Match --force NOT
# followed by -with-lease. ERE has no lookahead; "force then whitespace/quote/EOL"
# excludes "-force-with-lease" because the hyphen continues the token. Quote-
# tolerant so `git push '-f'` is caught.
test_deny 'git[[:space:]]+push[[:space:]]+.*--force([[:space:]"'"'"']|$)' 'git push --force (use --force-with-lease for the safe variant)'
test_deny 'git[[:space:]]+push[[:space:]]+['"'"'"]?(-f|--force)([[:space:]]|['"'"'"]|$)' 'git push -f / --force immediately after push'
test_deny 'git[[:space:]]+push([^;&|]*[[:space:]]+)?['"'"'"]?-f(['"'"'"]|[[:space:]]|$|[;&|])' 'git push with -f flag (use --force-with-lease for the safe variant)'
test_deny 'git[[:space:]]+reset[[:space:]]+--hard' 'git reset --hard (data loss)'
# Tolerate intervening flags before -f (`git clean -d -f`) so the destructive
# flag does not have to be the first token after `clean `.
if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+[^;&|]*-[a-zA-Z]*f' &&
   ! printf '%s' "$cmd" | grep -qE 'git[[:space:]]+clean[^;&|]*(-n|--dry-run)'; then
    deny 'git clean -f (untracked data loss)'
fi
test_deny 'dd[[:space:]].*of=/dev/(sd|nvme|hd|xvd)' 'dd to block device'
test_deny 'mkfs(\.[a-z0-9]+)?[[:space:]]+/dev/' 'mkfs on device'
test_deny 'chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/' 'chmod -R 777 on root'
# Tolerate a `--` end-of-options separator before the target path.
test_deny 'chown[[:space:]]+-R[[:space:]]+[^[:space:]]+[[:space:]]+(--[[:space:]]+)?/' 'chown -R on root'
# Anchor on start OR a command separator so `cd pkg && npm publish` is caught,
# not just publish at line start. Allow npm global flags before the subcommand
# (`npm --loglevel=error publish`) without matching `npm run publish-x`.
if printf '%s' "$cmd" | grep -qE "${_cmd_anchor}(npm|pnpm|yarn)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*publish([[:space:]]|$)" &&
   ! printf '%s' "$cmd" | grep -qE '(npm|pnpm|yarn)[[:space:]]+publish[^;&|]*--dry-run'; then
    deny 'package publish (use ship-hook, not direct publish)'
fi

allow
