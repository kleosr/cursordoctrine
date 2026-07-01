# inject-doctrine.ps1 - Cursor sessionStart injection.
#
# Emits {"additional_context": "<doctrine>"} via Write-HookJson (pure-ASCII JSON).
# Writes session-start-<cid>.txt so scope-git-sweep can filter by mtime.
# Fail open: missing files or any error -> "{}" (valid, empty). Never block or
# crash session start.

$ErrorActionPreference = 'SilentlyContinue'

$hookCommon = Join-Path $HOME '.agents\hooks\hook-common.ps1'
if (-not (Test-Path -LiteralPath $hookCommon)) {
    $hookCommon = Join-Path $PSScriptRoot 'hooks\hook-common.ps1'
}
try {
    if (Test-Path -LiteralPath $hookCommon) { . $hookCommon }
} catch {
    Write-Output '{}'
    exit 0
}
if (-not (Get-Command Write-HookJson -ErrorAction SilentlyContinue)) {
    Write-Output '{}'
    exit 0
}

$inputText = Read-HookStdin
$obj = $null
if ($inputText) {
    try { $obj = $inputText | ConvertFrom-Json } catch { $obj = $null }
}
if ($obj) { Write-SessionStartStamp $obj }

try {
    $doctrinePath = Join-Path $HOME '.cursor\doctrine.md'
    if (-not (Test-Path -LiteralPath $doctrinePath)) {
        $doctrinePath = Join-Path $PSScriptRoot 'doctrine.md'
    }
    $context = ''
    if (Test-Path -LiteralPath $doctrinePath) {
        $context = (Get-Content -Raw -LiteralPath $doctrinePath).Trim()
    }

    if (-not $context) { Write-Output '{}'; exit 0 }

    Write-HookJson @{ additional_context = $context }
} catch {
    Write-Output '{}'
}

exit 0
