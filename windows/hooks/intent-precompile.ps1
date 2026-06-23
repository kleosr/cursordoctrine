# intent-precompile.ps1 - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# Hook-owned: `prompt` (verbatim latest user message).
# Agent-owned: `intent` (Step 0 restatement), initial files[] blast radius,
# sharpened acceptance.
#
# Intent seeding: on topic change or fresh creation, the hook seeds `intent = ""`
# (empty). A blank intent is HONEST — it signals "not done yet" and keeps both
# intent-anchor (postToolUse nudge) and final-review (axis 0 FAIL) re-surfacing
# the gap until the agent rewrites it as a real Step 0 restatement of the SAME
# task, but clearer/better than the verbatim prompt. The hook never writes a
# [DRAFT] copy of the prompt: a verbatim-with-prefix seed looked "filled" to a
# lazy agent and never got regenerated. (Legacy [DRAFT] intents from older
# installs are still detected defensively by intent-anchor / final-review and
# nudged to be rewritten.) On continuation, existing intent is preserved verbatim.
#
# Topic change (automatic Jaccard detection): when the new prompt is dissimilar
# enough from the stored prompt, reset intent/files/decomposition/verifications.
# Continuation: update prompt only; preserve intent, files[], acceptance.
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

function Get-PromptTokenSet([string]$p) {
    $normalized = [regex]::Replace($p.ToLowerInvariant(), '[^a-z0-9 ]', ' ')
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($t in ($normalized -split '\s+')) {
        if ($t) { [void]$set.Add($t) }
    }
    return $set
}

function Test-TopicChanged([string]$newPrompt, [string]$oldPrompt) {
    if ([string]::IsNullOrWhiteSpace($oldPrompt)) { return $true }
    $newSet = Get-PromptTokenSet $newPrompt
    $oldSet = Get-PromptTokenSet $oldPrompt
    if ($newSet.Count -lt 3 -or $oldSet.Count -lt 3) { return $false }
    $intersection = 0
    foreach ($t in $newSet) {
        if ($oldSet.Contains($t)) { $intersection++ }
    }
    $union = $newSet.Count
    foreach ($t in $oldSet) {
        if (-not $newSet.Contains($t)) { $union++ }
    }
    if ($union -eq 0) { return $false }
    $threshold = 0.34
    if ($env:INTENT_TOPIC_THRESHOLD) {
        try { $threshold = [double]$env:INTENT_TOPIC_THRESHOLD } catch { }
    }
    return (($intersection / $union) -lt $threshold)
}

function New-ResetScope([string]$p) {
    return [ordered]@{
        prompt        = $p
        intent        = ''
        decomposition = @()
        verifications = @()
        files         = @()
        acceptance    = $defaultAcceptance
    }
}

$existing = $null
if (Test-Path -LiteralPath $scopePath) {
    try { $existing = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json } catch { }
}

try {
    if ($existing) {
        $oldPrompt = ''
        if ($existing.PSObject.Properties['prompt']) { $oldPrompt = [string]$existing.prompt }
        if (Test-TopicChanged $prompt $oldPrompt) {
            $ordered = New-ResetScope $prompt
        } else {
            $ordered = [ordered]@{ prompt = $prompt }
            foreach ($p in $existing.PSObject.Properties) {
                if ($p.Name -eq 'prompt') { continue }
                if ($p.Name -match '^_') { continue }
                if ($p.Name -in @('trace', 'allow_growth')) { continue }
                $ordered[$p.Name] = $p.Value
            }
            if (-not $ordered.Contains('intent')) { $ordered['intent'] = '' }
            if (-not $ordered.Contains('decomposition') -or $null -eq $ordered['decomposition']) { $ordered['decomposition'] = @() }
            if (-not $ordered.Contains('verifications') -or $null -eq $ordered['verifications']) { $ordered['verifications'] = @() }
            if (-not $ordered.Contains('files') -or $null -eq $ordered['files']) { $ordered['files'] = @() }
        }
    } else {
        $ordered = New-ResetScope $prompt
    }
    $json = $ordered | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
