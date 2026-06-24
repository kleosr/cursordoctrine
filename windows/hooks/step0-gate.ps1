# step0-gate.ps1 - preToolUse: hard Step 0 gate for file-write tools.
#
# Narrow enforcement (second hard lever beside permission-gate):
#   - Always allow writes to .scope.json (agent must be able to fill the contract).
#   - Deny other file writes when intent is empty or still [DRAFT].
#   - Deny when files[] already has >=1 real entry and decomposition[] is empty
#     (multi-file work needs a plan before the second file).
#
# Read/Grep/Shell are untouched — explore first, contract second, code third.
# No .scope.json in repo root -> fail open (non-doctrine projects).
# On internal errors -> fail open. Disable: STEP0_GATE_ENFORCE=0

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

function Allow-Step0 {
    Write-HookJson @{ permission = 'allow' }
    exit 0
}

function Deny-Step0 {
    param([string]$Reason)
    $userMsg = "BLOCKED by step0-gate: $Reason`n`nWrite intent (+ decomposition[] for multi-file tasks) to .scope.json first, then retry."
    Write-HookJson @{
        permission    = 'deny'
        user_message  = $userMsg
        agent_message = "$userMsg Do not skip Step 0 — persist the contract to .scope.json, not chat prose."
    }
    exit 0
}

if ($env:HOOKS_ENFORCE -eq '0' -or $env:STEP0_GATE_ENFORCE -eq '0') { Allow-Step0 }

$obj = Read-HookStdinJson
if (-not $obj) { Allow-Step0 }

$toolName = ''
if ($obj.PSObject.Properties['tool_name'] -and $obj.tool_name) {
    $toolName = [string]$obj.tool_name
}
if ($toolName -and $toolName -notmatch '^(Write|StrReplace|ApplyPatch|Edit|MultiEdit)$') { Allow-Step0 }

$root = Resolve-ProjectRoot $obj
if (-not $root) { Allow-Step0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path -LiteralPath $scopePath)) { Allow-Step0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { Allow-Step0 }
if (-not $sj) { Allow-Step0 }

$ti = $null
if ($obj.PSObject.Properties['tool_input'] -and $obj.tool_input) {
    $rawTi = $obj.tool_input
    if ($rawTi -is [string]) {
        try { $ti = $rawTi | ConvertFrom-Json } catch { $ti = $null }
    } else {
        $ti = $rawTi
    }
}
if (-not $ti) { Allow-Step0 }

$targetPath = ''
foreach ($k in @('path', 'file_path', 'filename', 'absolute_path', 'abs_path', 'target_file')) {
    if ($ti.PSObject.Properties[$k] -and $ti.$k) { $targetPath = [string]$ti.$k; break }
}
if (-not $targetPath) { Allow-Step0 }

$rel = ConvertTo-FwdPath $targetPath
if ($rel.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
    $rel = $rel.Substring($root.Length + 1)
}
$rel = $rel.TrimStart('/')
if (-not $rel) { Allow-Step0 }
if ($rel -ieq '.scope.json') { Allow-Step0 }

$intent = ''
if ($sj.PSObject.Properties['intent'] -and $sj.intent) { $intent = [string]$sj.intent }
$intent = $intent.Trim()
$intentEmpty = [string]::IsNullOrWhiteSpace($intent) -or ($intent -match '^\[DRAFT\]')
if ($intentEmpty) {
    Deny-Step0 'intent is empty — write your one-line Step 0 restatement to .scope.json before editing code.'
}

$realFiles = 0
if ($sj.PSObject.Properties['files'] -and $sj.files) {
    foreach ($e in @($sj.files)) {
        $s = [string]$e
        if (-not $s -or $s -match '^\s*<TODO' -or [string]::IsNullOrWhiteSpace($s) -or ($s.Trim() -ieq '.scope.json')) { continue }
        $realFiles++
    }
}

$decompCount = 0
if ($sj.PSObject.Properties['decomposition'] -and $sj.decomposition) {
    $decompCount = @($sj.decomposition).Count
}
if ($realFiles -ge 1 -and $decompCount -eq 0) {
    Deny-Step0 'files[] already has 1 entry and decomposition[] is empty — declare steps in .scope.json before editing another file.'
}

Allow-Step0
