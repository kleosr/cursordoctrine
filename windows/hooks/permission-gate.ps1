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
    # Belt-and-braces: if stdin was not the documented JSON shape, still gate
    # on the raw text rather than waving everything through.
    if (-not $cmd) { $cmd = $inputText }
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
    $userMsg = "BLOCKED by permission-gate: $Reason`n`nCommand: $shown`n`nIf this is genuinely intended, run it yourself in your terminal."
    Write-HookJson @{
        permission    = 'deny'
        user_message  = $userMsg
        agent_message = "$userMsg Do not retry verbatim. Ask the user to run it manually if it is truly intended."
    }
    exit 0
}

# --- POSIX-flavored ---------------------------------------------------------
# Anchored to start OR a command separator so `cd /tmp && rm -rf /` is caught,
# while `git rm`, `npm run rm-cache`, `echo "rm -rf /"` stay allowed.
Test-Deny '(?:^|[;&|]\s*)(?:sudo\s+)?rm\s+(?=[^;&|]*-[a-zA-Z]*[rR])(?=[^;&|]*-[a-zA-Z]*[fF])[^;&|]*\s+/' 'destructive rm -rf on absolute path (use relative paths or be more specific)'
Test-Deny ':\(\)\{\s*:\|:&\s*\};:|bash\s+-c\s+["'']*:\s*\(\)\{' 'reverse shell / fork-bomb pattern'
Test-Deny 'curl\s.*\|\s*(sudo\s*)?(bash|sh|zsh|dash|ash)' 'curl piped to shell'
Test-Deny 'wget\s.*\|\s*(sudo\s*)?(bash|sh|zsh|dash|ash)' 'wget piped to shell'
Test-Deny 'git\s+push\s+.*--force(-with-lease)?(\s|$)' 'git push --force'
Test-Deny 'git\s+push\s+(-f|--force)(\s|$)' 'git push -f / --force'
Test-Deny 'git\s+reset\s+--hard' 'git reset --hard (data loss)'
Test-Deny 'git\s+clean\s+(?![^;&|]*(?:-n|--dry-run))-[a-zA-Z]*f' 'git clean -f (untracked data loss)'
Test-Deny 'dd\s.*of=/dev/(sd|nvme|hd|xvd)' 'dd to block device'
Test-Deny 'mkfs(\.[a-z0-9]+)?\s+/dev/' 'mkfs on device'
Test-Deny 'chmod\s+-R\s+777\s+/' 'chmod -R 777 on root'
Test-Deny 'chown\s+-R\s+[^\s]+\s+/' 'chown -R on root'
Test-Deny '^(npm|pnpm|yarn)\s+publish(?![^;&|]*--dry-run)(\s|$)' 'package publish (use ship-hook, not direct publish)'

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
