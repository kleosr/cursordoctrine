# intent-precompile.ps1 - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# Hook-owned: `prompt` (verbatim latest user message).
# Agent-owned: `intent` (Step 0 restatement), initial files[] blast radius,
# sharpened acceptance.
#
# Intent seeding: on new task or fresh creation, the hook writes
# `intent = "[DRAFT] <prompt>"` — a provisional placeholder so the field is
# never blank. The agent refines it into a proper Step 0 restatement (removing
# the [DRAFT] prefix). intent-anchor detects the [DRAFT] prefix and keeps
# nudging until the agent rewrites it. On continuation, existing intent is
# preserved verbatim.
#
# Continuation: update prompt only; preserve intent, files[], acceptance.
# New task (/new, "new task:", "new task —"): reset and seed [DRAFT] intent.
#
# Skips hook-generated auto-submits. Never blocks. Disable: HOOKS_ENFORCE=0 or
# INTENT_PRECOMPILE_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:INTENT_PRECOMPILE_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$prompt = ''
if ($obj.PSObject.Properties['prompt']) { $prompt = [string]$obj.prompt }
$prompt = $prompt.Trim()
if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

if ($prompt -match '(?m)^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER|VERIFY MILESTONE)') { exit 0 }

$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
$defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

function Test-NewTaskPrompt([string]$p) {
    $t = $p.TrimStart()
    if ($t -match '(?i)^(/new|new task:)') { return $true }
    if ($t -match '(?i)^new task [—\-]') { return $true }
    return $false
}

$existing = $null
if (Test-Path -LiteralPath $scopePath) {
    try { $existing = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json } catch { }
}

try {
    if (Test-NewTaskPrompt $prompt) {
        $ordered = [ordered]@{
            prompt        = $prompt
            intent        = "[DRAFT] $prompt"
            decomposition = @()
            verifications = @()
            files         = @()
            acceptance    = $defaultAcceptance
        }
    } elseif ($existing) {
        $ordered = [ordered]@{ prompt = $prompt }
        foreach ($p in $existing.PSObject.Properties) {
            if ($p.Name -eq 'prompt') { continue }
            if ($p.Name -match '^_') { continue }
            if ($p.Name -in @('trace', 'allow_growth')) { continue }
            $ordered[$p.Name] = $p.Value
        }
        if (-not $ordered.Contains('intent')) { $ordered['intent'] = "[DRAFT] $prompt" }
        if (-not $ordered.Contains('decomposition') -or $null -eq $ordered['decomposition']) { $ordered['decomposition'] = @() }
        if (-not $ordered.Contains('verifications') -or $null -eq $ordered['verifications']) { $ordered['verifications'] = @() }
        if (-not $ordered.Contains('files') -or $null -eq $ordered['files']) { $ordered['files'] = @() }
    } else {
        $ordered = [ordered]@{
            prompt        = $prompt
            intent        = "[DRAFT] $prompt"
            decomposition = @()
            verifications = @()
            files         = @()
            acceptance    = $defaultAcceptance
        }
    }
    $json = $ordered | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
