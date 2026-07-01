# permission-gate.ps1 - beforeShellExecution for Cursor.
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

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:PERM_GATE_ENFORCE -eq '0') {
    Write-HookJson @{ permission = 'allow' }
    exit 0
}

# Without BOM-safe decode the JSON never parses, the raw-text fallback below
# matches deny patterns anywhere in the envelope (false positives), and the
# deny message leaks conversation id / transcript path / user email into the UI.
$inputText = Read-HookStdin

$cmd = ''
if ($inputText) {
    try {
        $obj = $inputText | ConvertFrom-Json
        if ($obj -and $obj.PSObject.Properties['command']) {
            $cmd = [string]$obj.command
        }
    } catch {
        $cmd = ''
    }
    # Belt-and-braces: extract command from malformed JSON; never gate on the raw
    # envelope (leaks conversation_id / transcript_path into deny UI).
    if (-not $cmd -and $inputText -match '"command"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"') {
        $cmd = $Matches[1] -replace '\\"', '"' -replace '\\/', '/'
    }
    if (-not $cmd -and $inputText -and $inputText -notmatch '^\s*\{') {
        $cmd = $inputText.Trim()
    }
}

if (-not $cmd) {
    Write-HookJson @{ permission = 'allow' }
    exit 0
}

function Test-Deny {
    param([string]$Pattern, [string]$Reason)
    if ($cmd -match $Pattern) { Deny $Reason }
}

function Deny {
    param([string]$Reason)
    # Truncate the echo: the command can be a multi-hundred-char one-liner and
    # the UI message only needs enough to identify it.
    $shown = if ($cmd.Length -gt 400) { $cmd.Substring(0, 400) + '...' } else { $cmd }
    $shown = Redact-SecretsFromIntent $shown
    $userMsg = "BLOCKED by permission-gate: $Reason`n`nCommand: $shown`n`nIf this is genuinely intended, run it yourself in your terminal."
    Write-HookJson @{
        permission    = 'deny'
        user_message  = $userMsg
        agent_message = "$userMsg Do not retry verbatim. Ask the user to run it manually if it is truly intended."
    }
    exit 0
}

# --- POSIX-flavored ---------------------------------------------------------
# (?m): ^ matches start of each line, so `cd /tmp\nrm -rf /` (newline-separated)
# is caught on the rm line. Mirrors grep's per-line ^ on the bash side. Quote-
# tolerant path (`rm -rf "/"`) and token-boundary flags (no false positive on
# `rm -f /tmp/data-r` — the two-lookahead form matched a hyphenated path
# segment ending in `r` plus a real `-f`; the three-pattern form below requires
# r and f in actual flag tokens).
$cmdAnchor = '(?:^|[;&|]\s*)(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*'
$rmDestPath = '["'']?(/|~(/|["'']|\s|$))'
Test-Deny "(?m)${cmdAnchor}(?:sudo\s+)?rm\s+([^;&|]*\s)?-[a-zA-Z]*([rR][fF]|[fF][rR])[a-zA-Z]*(\s+--\S+)*\s+${rmDestPath}" 'destructive rm -rf on absolute or home path (use relative paths or be more specific)'
Test-Deny "(?m)${cmdAnchor}(?:sudo\s+)?rm\s+[^;&|]*-[a-zA-Z]*[rR][a-zA-Z]*\s+[^;&|]*-[a-zA-Z]*[fF][a-zA-Z]*[^;&|]*\s+${rmDestPath}" 'destructive rm -rf on absolute or home path (separate -r/-f flags)'
Test-Deny "(?m)${cmdAnchor}(?:sudo\s+)?rm\s+[^;&|]*-[a-zA-Z]*[fF][a-zA-Z]*\s+[^;&|]*-[a-zA-Z]*[rR][a-zA-Z]*[^;&|]*\s+${rmDestPath}" 'destructive rm -rf on absolute or home path (separate -f/-r flags)'
Test-Deny ':\(\)\{\s*:\|:&\s*\};:|bash\s+-c\s+["'']*:\s*\(\)\{' 'reverse shell / fork-bomb pattern'
# sudo may carry flags between sudo and the shell (`sudo -E bash`); tolerate
# them so a single intervening flag no longer bypasses the rule.
Test-Deny 'curl\s.*\|\s*(sudo(\s+-\S+)*\s+)?(bash|sh|zsh|dash|ash)' 'curl piped to shell'
Test-Deny 'wget\s.*\|\s*(sudo(\s+-\S+)*\s+)?(bash|sh|zsh|dash|ash)' 'wget piped to shell'
# Process substitution is the no-`|` twin of curl|sh; same threat model.
Test-Deny '<\(\s*(curl|wget)\s' 'curl/wget via process substitution piped to shell'
# Quote-tolerant so `git push '-f' origin main` is caught, not just the bare form;
# the trailing class allows the closing quote right after the flag.
Test-Deny 'git\s+push\s+.*--force(?!\-with\-lease)(\s|$)' 'git push --force (use --force-with-lease for the safe variant)'
Test-Deny 'git\s+push\s+["'']?(-f|--force)(\s|["'']|$)' 'git push -f / --force immediately after push'
Test-Deny 'git\s+push\b[^;&|]*\s["'']?-f["'']?(\s|["'']|$|[;&|])' 'git push with -f flag (use --force-with-lease for the safe variant)'
Test-Deny 'git\s+reset\s+--hard' 'git reset --hard (data loss)'
# Tolerate intervening flags before -f (`git clean -d -f`) so the destructive
# flag does not have to be the first token after `clean `.
Test-Deny 'git\s+clean\s+(?![^;&|]*(?:-n|--dry-run))[^;&|]*-[a-zA-Z]*f' 'git clean -f (untracked data loss)'
Test-Deny 'dd\s.*of=/dev/(sd|nvme|hd|xvd)' 'dd to block device'
Test-Deny 'mkfs(\.[a-z0-9]+)?\s+/dev/' 'mkfs on device'
Test-Deny 'chmod\s+-R\s+777\s+/' 'chmod -R 777 on root'
# Tolerate a `--` end-of-options separator before the target path.
Test-Deny 'chown\s+-R\s+[^\s]+\s+(--\s+)?/' 'chown -R on root'
# (?m) so a newline-separated `cd pkg\nnpm publish` is caught on the publish
# line. Allow npm global flags before the subcommand (`npm --loglevel=error
# publish`) without matching `npm run publish-x`.
Test-Deny "(?m)${cmdAnchor}(npm|pnpm|yarn)\s+(-\S+\s+)*publish(?![^;&|]*--dry-run)(\s|$)" 'package publish (use ship-hook, not direct publish)'

# --- Windows equivalents (the agent shell here IS PowerShell) ---------------
# iwr/irm | iex is the moral twin of curl|sh.
Test-Deny '\b(iwr|irm|curl|wget|Invoke-WebRequest|Invoke-RestMethod)\b[^|]*\|\s*(iex\b|Invoke-Expression)' 'web download piped to Invoke-Expression'
# Disk-level destruction, twin of mkfs / dd-to-device.
Test-Deny '\b(Format-Volume|Clear-Disk)\b' 'disk format / clear (destructive)'
# Recursive+forced delete of a bare drive root, user-profile root, or
# C:\Users / C:\Windows. Twin of rm -rf /. Composed checks instead of one
# unreadable regex; subfolder deletes (e.g. C:\Temp\x) stay allowed.
$rmVerb    = '(?:^|[;&|]\s*)(?:Remove-Item|rm|ri|del|erase|rd|rmdir)\s'
$rootPath  = '(?:^|[\s"''])(?:[A-Za-z]:[\\/]{0,2}|[A-Za-z]:[\\/](?:Users|Windows)[\\/]?|\$(?:env:USERPROFILE|HOME)[\\/]?)["'']?\s*(?:$|[;&|-])'
if (($cmd -match $rmVerb) -and ($cmd -match $rootPath) -and ($cmd -match '(?:-Recurse\b|/s\b)') -and ($cmd -match '(?:-Force\b|/q\b)')) {
    Deny 'recursive forced delete of a drive root / Users / Windows / profile root'
}

Write-HookJson @{ permission = 'allow' }
exit 0
