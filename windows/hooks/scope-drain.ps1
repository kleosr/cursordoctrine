# scope-drain.ps1 - postToolUse: drain the stashed scope reminder into additional_context.
#
# Pairs with scope-refresh.ps1 (afterFileEdit). afterFileEdit output is not
# consumed by Cursor, so scope-refresh writes a per-cid stash file and THIS
# hook delivers it on the next tool boundary. One-shot: the stash is deleted
# on read, so a hook error can't replay it forever.
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

$pending = Join-Path $HOME ".cursor\.hooks-pending\scope-$cid.txt"
if (-not (Test-Path -LiteralPath $pending)) { exit 0 }

$msg = ''
try {
    $msg = Get-Content -LiteralPath $pending -Raw
    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
} catch { exit 0 }

if ([string]::IsNullOrWhiteSpace($msg)) { exit 0 }
Write-HookJson @{ additional_context = $msg }
exit 0
