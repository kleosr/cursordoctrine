# inject-doctrine.ps1 - Cursor sessionStart injection.
#
# Emits {"additional_context": "<doctrine>"} via Write-HookJson (pure-ASCII JSON).
# Fail open: missing files or any error -> "{}" (valid, empty). Never block or
# crash session start.

$ErrorActionPreference = 'SilentlyContinue'

function Emit-EmptyJson {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes('{}')
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

$null = [Console]::In.ReadToEnd()

$hookCommon = Join-Path $HOME '.agents\hooks\hook-common.ps1'
if (-not (Test-Path -LiteralPath $hookCommon)) {
    $hookCommon = Join-Path $PSScriptRoot 'hooks\hook-common.ps1'
}
try {
    if (Test-Path -LiteralPath $hookCommon) { . $hookCommon }
} catch {
    Emit-EmptyJson
    exit 0
}
if (-not (Get-Command Write-HookJson -ErrorAction SilentlyContinue)) {
    Emit-EmptyJson
    exit 0
}

try {
    $doctrinePath = Join-Path $PSScriptRoot 'doctrine.md'
    $context = ''
    if (Test-Path -LiteralPath $doctrinePath) {
        $context = (Get-Content -Raw -LiteralPath $doctrinePath).Trim()
    }

    if (-not $context) { Emit-EmptyJson; exit 0 }

    Write-HookJson @{ additional_context = $context }
} catch {
    Emit-EmptyJson
}

exit 0
