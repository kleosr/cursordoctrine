# scope-refresh.ps1 - afterFileEdit: re-stash .scope.json for scope-drain to deliver.
#
# Per-edit re-injection against Salience Dilution: as a turn fills with code,
# logs and errors, the intent declared at Step 0 shrinks to a rounding error
# and the agent drifts. afterFileEdit fires right after every Write; this hook
# reads the contract and stashes a one-line reminder to the per-cid pending
# file. scope-drain.ps1 (postToolUse, fires next) delivers it as
# additional_context. Cursor does not consume afterFileEdit output directly,
# which is why the stash-and-drain pair exists.
#
# One state file (scope-<cid>.txt), no hashes, no latches, no per-prompt
# detection. The agent owns .scope.json; this hook only re-surfaces it.
# Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SCOPE_REFRESH_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$cid = Get-SafeConversationId $obj
$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path -LiteralPath $scopePath)) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

$intent    = if ($sj.PSObject.Properties['intent']    -and $sj.intent)    { [string]$sj.intent } else { '' }
$files     = if ($sj.PSObject.Properties['files']     -and $sj.files)     { (@($sj.files) -join ', ') } else { '(none yet)' }
$acceptance = if ($sj.PSObject.Properties['acceptance'] -and $sj.acceptance) { [string]$sj.acceptance } else { '' }

$msg = "SCOPE REMINDER (re-injected after your edit):`n  intent: $intent`n  files: $files"
if ($acceptance) { $msg += "`n  acceptance: $acceptance" }
$msg += "`n`nConfirm this edit advances intent and stays inside files[]. If not, reconcile .scope.json or revert."

$pending = Join-Path $HOME ".cursor\.hooks-pending\scope-$cid.txt"
try {
    New-Item -ItemType Directory -Force (Split-Path $pending) | Out-Null
    [System.IO.File]::WriteAllText($pending, $msg, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
