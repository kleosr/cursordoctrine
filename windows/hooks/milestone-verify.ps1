# milestone-verify.ps1 - postToolUse: tri-role Verifier for doctrine-ultra.
#
# When the agent declares a `decomposition[]` at Step 0 (Thinker), each step's
# `expected_files[]` is the milestone for that step. As the agent edits (Worker),
# scope-refresh records paths into .scope.json's `files[]`. When a step's
# expected_files are ALL in files[] AND no verdict has been recorded for that
# step, this hook emits a VERIFY MILESTONE reminder as additional_context.
#
# The agent emits verdicts in chat: "ACCEPT step N" or "REVISE step N: <one-line
# diagnosis>". This hook scrapes the transcript backward through assistant turns
# for the most recent verdict matching a still-unverified step, and writes it
# into .scope.json's `verifications[]` (hook-owned).
#
# Auto-PENDING: when a step's expected_files are all touched AND no verdict is
# recorded for it, the hook writes a {verdict:"PENDING"} entry before emitting
# the VERIFY MILESTONE reminder — so verifications[] is never blank once a
# milestone is reached, even if the model stays silent. The model's later
# ACCEPT/REVISE (scraped by Phase 1) upgrades PENDING -> ACCEPT/REVISE.
#
# Tri-role (Trinity-style): Thinker=decomposition at Step 0,
# Worker=edits+scope-refresh, Verifier=this hook + final-review axis 7.
# Doctrine-ultra: the harness adds structure; the model fills it. The hook
# never decides correctness — only the model does.
#
# Silent exits (YAGNI rung 1): .scope.json missing; all steps already verified;
# no expected_files completed; kill switch set. When decomposition is empty BUT
# the session has touched >= 2 files, a DECOMPOSE nudge fires instead (per-cid
# throttle, mirrors intent-anchor) — the doctrine requires decomposition for
# multi-file tasks. Never blocks. Disable: HOOKS_ENFORCE=0 or MILESTONE_VERIFY_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:MILESTONE_VERIFY_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path -LiteralPath $scopePath)) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

# Need a decomposition array. Empty/missing = YAGNI rung 1 — BUT if the
# session has touched >= 2 files, the task is likely multi-step and the
# doctrine REQUIRES decomposition. Nudge the agent (per-cid throttle mirrors
# intent-anchor), then silent. Closes the gap where a session touches many
# files with zero steps declared (the doctrine's multi-file rule unenforced).
$decomp = @()
if ($sj.PSObject.Properties['decomposition'] -and $sj.decomposition) { $decomp = @($sj.decomposition) }

if ($decomp.Count -eq 0) {
    # Count real session files (exclude .scope.json + placeholders).
    $realFiles = @()
    if ($sj.PSObject.Properties['files'] -and $sj.files) {
        $realFiles = @($sj.files | Where-Object { $_ -and "$_".Trim() -and "$_" -notmatch '^\s*<' -and ("$_".Trim()) -ine '.scope.json' })
    }
    if ($realFiles.Count -ge 2) {
        $cid = Get-SafeConversationId $obj
        $pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
        $dflag = Join-Path $pendingDir "decompose-$cid.flag"
        $nudge = Read-NudgeFlag $dflag
        $lastCount = $nudge.LastCount
        $nudgeCount = $nudge.NudgeCount
        $fc = $realFiles.Count
        # Effectively unlimited (was 8 — exhausted mid-session on a 30-file
        # task, leaving decomposition empty with no further signal). A contract
        # that can be emptied by an ignoring agent is worse than a noisy one.
        # Re-nudges still only fire when files[] grows (avoids spam). Override:
        # DECOMPOSE_NUDGE_CAP.
        $decomposeCap = 99999
        if ($env:DECOMPOSE_NUDGE_CAP) {
            try { $decomposeCap = [int]$env:DECOMPOSE_NUDGE_CAP } catch { }
        }
        # Re-nudge only when files[] grew since last nudge AND under the cap.
        if (($lastCount -lt 0 -or $fc -gt $lastCount) -and $nudgeCount -lt $decomposeCap) {
            $nudgeCount++
            Write-NudgeFlag $dflag $fc $nudgeCount
            $sample = (($realFiles | Select-Object -First 5) -join ', ')
            $msg = "DECOMPOSE: this session has touched $fc file(s) ($sample) but .scope.json has no decomposition[]. The doctrine requires decomposition for any multi-step or multi-file task. Declare it now: each entry needs step (int), subtask (one-line string), and expected_files (array of paths). This nudge re-fires on each new file until decomposition is filled (nudge $nudgeCount of $decomposeCap). The final review's axis 7 will FAIL on a multi-file task with no decomposition."
            Write-HookJson @{ additional_context = $msg }
        }
    }
    exit 0
}

# Files touched so far (hook-owned by scope-refresh).
$files = @()
if ($sj.PSObject.Properties['files'] -and $sj.files) {
    $files = @($sj.files | ForEach-Object { ConvertTo-ScopeRelativePath ([string]$_) $root } | Where-Object { $_ })
}
if ($files.Count -eq 0) { exit 0 }

# Verifications recorded so far (hook-owned by this hook).
$verifications = @()
if ($sj.PSObject.Properties['verifications'] -and $sj.verifications) { $verifications = @($sj.verifications) }
# Two views: $anyVerdict = any verdict drives Phase 2 emit-once skip;
# $recordedVerdict = step→verdict string for Phase 1 upgrade guard (ACCEPT is
# terminal; PENDING/REVISE may upgrade when scraped differs).
$anyVerdict = @{}
$recordedVerdict = @{}
foreach ($v in $verifications) {
    if ($v -and $v.PSObject.Properties['step'] -and $v.PSObject.Properties['verdict']) {
        try {
            $s = [int]$v.step
            $anyVerdict[$s] = $true
            $recordedVerdict[$s] = [string]$v.verdict
        } catch { }
    }
}

function Test-AllowVerdictUpgrade($recorded, [int]$stepNum, [string]$scrapedVerdict) {
    if (-not $recorded.ContainsKey($stepNum)) { return $true }
    $rv = $recorded[$stepNum]
    if ($rv -ieq 'ACCEPT') { return $false }
    if ($rv -ieq $scrapedVerdict) { return $false }
    return $true
}

# --- Phase 1: scrape most-recent ACCEPT/REVISE verdict from the transcript ----
# Steps the agent actually declared — a scraped verdict for a step that is NOT
# in decomposition[] is ignored (hallucinated or stale step number), so it does
# not pollute verifications[] with entries the milestone logic will never clear.
$decompSteps = @{}
foreach ($d in $decomp) { if ($d -and $d.PSObject.Properties['step']) { try { $decompSteps[[int]$d.step] = $true } catch { } } }

$scraped = Get-LastVerdict $obj
if ($scraped -and $decompSteps.ContainsKey($scraped.step) -and (Test-AllowVerdictUpgrade $recordedVerdict $scraped.step $scraped.verdict)) {
    $entry = [PSCustomObject]@{
        step      = $scraped.step
        verdict   = $scraped.verdict
        diagnosis = $scraped.diagnosis
    }
    $newVerifs = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($v in $verifications) {
        $existingStep = 0
        if ($v -and $v.PSObject.Properties['step']) { try { $existingStep = [int]$v.step } catch { } }
        if ($existingStep -eq $scraped.step) { $newVerifs.Add($entry) | Out-Null; $replaced = $true }
        else { $newVerifs.Add($v) | Out-Null }
    }
    if (-not $replaced) { $newVerifs.Add($entry) | Out-Null }
    # Sync $verifications to the just-built list so Phase 2 below appends onto it
    # instead of the stale top-of-hook copy — otherwise the PENDING write-back
    # drops this scraped verdict when both phases fire for different steps.
    $verifications = @($newVerifs.ToArray())
    $anyVerdict[$scraped.step] = $true
    $recordedVerdict[$scraped.step] = $scraped.verdict
    $phase1Verifs = @($newVerifs.ToArray())
    if (Update-ScopeJson $scopePath { param($scope); $scope.verifications = $phase1Verifs; return $scope }) {
        try { $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json } catch { }
    }
}

# --- Phase 2: emit reminder for first unverified completed milestone --------
$filesSet = @{}
foreach ($f in $files) { $filesSet[$f.ToLowerInvariant()] = $true }

foreach ($step in $decomp) {
    if (-not $step -or -not $step.PSObject.Properties['step']) { continue }
    try { $stepNum = [int]$step.step } catch { continue }
    if ($anyVerdict.ContainsKey($stepNum)) { continue }

    $expected = @()
    if ($step.PSObject.Properties['expected_files'] -and $step.expected_files) {
        $expected = @($step.expected_files | ForEach-Object { ConvertTo-ScopeRelativePath ([string]$_) $root } | Where-Object { $_ })
    }
    if ($expected.Count -eq 0) { continue }

    $allTouched = $true
    foreach ($ef in $expected) {
        if (-not $filesSet.ContainsKey($ef.ToLowerInvariant())) { $allTouched = $false; break }
    }
    if (-not $allTouched) { continue }

    # Milestone reached. Auto-record a PENDING verdict so verifications[] is
    # never blank once a step's expected_files are all touched — even if the
    # model never emits ACCEPT/REVISE. The model's later ACCEPT/REVISE (scraped
    # by Get-LastVerdict in Phase 1) upgrades PENDING -> ACCEPT/REVISE via the
    # existing $existingStep replacement at the top of this hook.
    $entry = [PSCustomObject]@{
        step      = $stepNum
        verdict   = 'PENDING'
        diagnosis = 'auto: all expected_files touched'
    }
    $newVerifs = New-Object System.Collections.Generic.List[object]
    foreach ($v in $verifications) { $newVerifs.Add($v) | Out-Null }
    $newVerifs.Add($entry) | Out-Null
    $phase2Verifs = @($newVerifs.ToArray())
    Update-ScopeJson $scopePath { param($scope); $scope.verifications = $phase2Verifs; return $scope } | Out-Null

    $subtask = if ($step.PSObject.Properties['subtask'] -and $step.subtask) { [string]$step.subtask } else { '(no subtask declared)' }
    $expectedList = $expected -join ', '
    $total = $decomp.Count
    $acceptForm = "ACCEPT step $stepNum"
    $reviseForm = "REVISE step ${stepNum}: one-line diagnosis"
    $msg = "VERIFY MILESTONE step $stepNum of $total`n  subtask: $subtask`n  expected_files: $expectedList (all touched; recorded as PENDING in verifications[])`n  Emit '$acceptForm' to proceed, or '$reviseForm' to repair."
    Write-HookJson @{ additional_context = $msg }
    exit 0
}

exit 0
