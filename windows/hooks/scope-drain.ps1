# scope-drain.ps1 - postToolUse: drain stashed reminders into additional_context.
#
# Pairs with scope-refresh.ps1 (afterFileEdit) and intent-precompile.ps1
# (beforeSubmitPrompt). afterFileEdit output is not consumed by Cursor, so
# scope-refresh writes a per-cid stash file and THIS hook delivers it on the
# next tool boundary. intent-precompile writes precompile-<cid>.txt when the
# contract is incomplete at prompt submit; this hook delivers that on the first
# postToolUse too. One-shot: each stash is deleted on read.
#
# Fires on every postToolUse. Most fires find no stash (scope-refresh only
# writes one after an actual edit) and emit nothing. No matcher on postToolUse
# is supported by Cursor, so the gate is "stash file exists."
# Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SCOPE_REFRESH_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
$cid = Get-SafeConversationId $obj

$msgs = New-Object System.Collections.Generic.List[string]

$precompile = Join-Path $HOME ".cursor\.hooks-pending\precompile-$cid.txt"
if (Test-Path -LiteralPath $precompile) {
    try {
        $part = Get-Content -LiteralPath $precompile -Raw
        Remove-Item -LiteralPath $precompile -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($part)) { $msgs.Add($part.Trim()) | Out-Null }
    } catch { }
}

$pending = Join-Path $HOME ".cursor\.hooks-pending\scope-$cid.txt"
if (Test-Path -LiteralPath $pending) {
    try {
        $part = Get-Content -LiteralPath $pending -Raw
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($part)) { $msgs.Add($part.Trim()) | Out-Null }
    } catch { }
}

if ($msgs.Count -eq 0) { exit 0 }
Write-HookJson @{ additional_context = ($msgs -join "`n`n") }
exit 0
