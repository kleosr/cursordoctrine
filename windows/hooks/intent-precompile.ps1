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
# Step 0 nudge: when intent is empty/[DRAFT] or acceptance is the default seed,
# stashes STEP 0 CONTRACT to ~/.cursor/.hooks-pending/precompile-<cid>.txt for
# scope-drain on the first postToolUse. Clears intent-anchor throttle so
# edit-time nudges can fire again this turn.
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

$forceNewTask = $false
if ($prompt -match '^\s*(/new\b|new\s+task:)\s*(.*)$') {
    $prompt = $Matches[2].Trim()
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }
    $forceNewTask = $true
}

if (Test-IsHookGeneratedQuery $prompt) { exit 0 }
if ((Test-IsPlanModeEvent $obj) -or (Test-IsPlanOnlyPrompt $prompt)) { exit 0 }

$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
$defaultAcceptance = $DefaultAcceptance

Ensure-SessionStartStamp $obj

function Get-PromptTokenSet([string]$p) {
    $normalized = [regex]::Replace($p.ToLowerInvariant(), '[^\p{L}\p{Nd} ]', ' ')
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
        if ($forceNewTask -or (Test-TopicChanged $prompt $oldPrompt)) {
            $ordered = New-ResetScope $prompt
            # ponytail: topic change must clear per-cid nudge flags or stale filesCount silences intent-anchor/decompose for the new task
            $cid = Get-SafeConversationId $obj
            if ($cid) {
                $pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
                foreach ($n in @("intent-anchored-$cid.flag", "decompose-$cid.flag")) {
                    $fp = Join-Path $pendingDir $n
                    if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
                }
            }
        } else {
            $ordered = [ordered]@{ prompt = $prompt }
            foreach ($p in $existing.PSObject.Properties) {
                if ($p.Name -eq 'prompt') { continue }
                if ($p.Name -match '^_') { continue }
                if ($p.Name -in @('trace', 'allow_growth')) { continue }
                $ordered[$p.Name] = $p.Value
            }
            $intentVal = $null
            if ($ordered.Contains('intent')) { $intentVal = $ordered['intent'] }
            if ($null -eq $intentVal -or -not ($intentVal -is [string])) { $ordered['intent'] = '' }
            if (-not $ordered.Contains('decomposition') -or $null -eq $ordered['decomposition']) { $ordered['decomposition'] = @() }
            if (-not $ordered.Contains('verifications') -or $null -eq $ordered['verifications']) { $ordered['verifications'] = @() }
            if (-not $ordered.Contains('files') -or $null -eq $ordered['files']) { $ordered['files'] = @() }
            $acc = $null
            if ($ordered.Contains('acceptance')) { $acc = $ordered['acceptance'] }
            if ($null -eq $acc -or -not ($acc -is [string])) { $ordered['acceptance'] = '' }
        }
    } else {
        $ordered = New-ResetScope $prompt
    }
    $json = $ordered | ConvertTo-Json -Depth 8
    if (Test-Path -LiteralPath $scopePath) {
        $replacement = $json
        Update-ScopeJson $scopePath { param($scope); return ($replacement | ConvertFrom-Json) } | Out-Null
    } else {
        Write-ScopeJsonAtomic $scopePath $json
    }

    $intentVal = ''
    if ($ordered.Contains('intent')) { $intentVal = [string]$ordered['intent'] }
    $acceptVal = ''
    if ($ordered.Contains('acceptance') -and $null -ne $ordered['acceptance']) { $acceptVal = [string]$ordered['acceptance'] }
    $needsStep0 = [string]::IsNullOrWhiteSpace($intentVal) -or ($intentVal -match '^\[DRAFT\]') -or [string]::IsNullOrWhiteSpace($acceptVal) -or ($acceptVal -ieq $defaultAcceptance)
    if ($needsStep0) {
        $cid = Get-SafeConversationId $obj
        if ($cid) {
            $pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
            $anchorFlag = Join-Path $pendingDir "intent-anchored-$cid.flag"
            if (Test-Path -LiteralPath $anchorFlag) {
                Remove-Item -LiteralPath $anchorFlag -Force -ErrorAction SilentlyContinue
            }
            $msg = "STEP 0 CONTRACT (re-injected at prompt submit): .scope.json was seeded by intent-precompile. Fill agent-owned fields NOW before your first edit:`n  - intent: empty — write your one-line restatement (NOT the verbatim prompt)`n  - acceptance: sharpen from the default seed to this task's real done-check`n  - decomposition[]: declare steps if this task is multi-file or multi-step`n`nCurrent prompt: $prompt"
            $stash = Join-Path $pendingDir "precompile-$cid.txt"
            try {
                New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
                [System.IO.File]::WriteAllText($stash, $msg, [System.Text.UTF8Encoding]::new($false))
            } catch { }
        }
    }
} catch { }

exit 0
