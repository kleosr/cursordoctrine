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
# Tri-role (Trinity-style): Thinker=decomposition at Step 0,
# Worker=edits+scope-refresh, Verifier=this hook + final-review axis 7.
# Doctrine-ultra: the harness adds structure; the model fills it. The hook
# never decides correctness — only the model does.
#
# Silent exits (YAGNI rung 1): .scope.json missing; all steps already verified;
# no expected_files completed; kill switch set. When decomposition is empty BUT
# the session has touched >= 1 file, a DECOMPOSE nudge fires instead (per-cid
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
# session has touched >= 1 file, the task is likely multi-step and the
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
    if ($realFiles.Count -ge 1) {
        $cid = Get-SafeConversationId $obj
        $pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
        $dflag = Join-Path $pendingDir "decompose-$cid.flag"
        $lastCount = -1
        $nudgeCount = 0
        if (Test-Path $dflag) {
            try {
                $parts = (Get-Content $dflag -Raw -ErrorAction SilentlyContinue).Trim() -split ':'
                if ($parts.Count -ge 1) { $lastCount = [int]$parts[0] }
                if ($parts.Count -ge 2) { $nudgeCount = [int]$parts[1] }
            } catch { }
        }
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
            New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
            Set-Content -LiteralPath $dflag -Value "${fc}:${nudgeCount}" -ErrorAction SilentlyContinue
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
    $files = @($sj.files) | ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') }
}
if ($files.Count -eq 0) { exit 0 }

# Verifications recorded so far (hook-owned by this hook).
$verifications = @()
if ($sj.PSObject.Properties['verifications'] -and $sj.verifications) { $verifications = @($sj.verifications) }
$verifiedSteps = @{}
foreach ($v in $verifications) {
    if ($v -and $v.PSObject.Properties['step']) {
        try { $verifiedSteps[[int]$v.step] = $true } catch { }
    }
}

# --- Phase 1: scrape most-recent ACCEPT/REVISE verdict from the transcript ----
$scraped = Get-LastVerdict $obj
if ($scraped -and -not $verifiedSteps.ContainsKey($scraped.step)) {
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
    $verifiedSteps[$scraped.step] = $true
    try {
        $ordered = [ordered]@{}
        foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
        $ordered['verifications'] = @($newVerifs.ToArray())
        $json = $ordered | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
        $sj = $json | ConvertFrom-Json
    } catch { }
}

# --- Phase 2: emit reminder for first unverified completed milestone --------
$filesSet = @{}
foreach ($f in $files) { $filesSet[$f.ToLowerInvariant()] = $true }

foreach ($step in $decomp) {
    if (-not $step -or -not $step.PSObject.Properties['step']) { continue }
    try { $stepNum = [int]$step.step } catch { continue }
    if ($verifiedSteps.ContainsKey($stepNum)) { continue }

    $expected = @()
    if ($step.PSObject.Properties['expected_files'] -and $step.expected_files) {
        $expected = @($step.expected_files) | ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') }
    }
    if ($expected.Count -eq 0) { continue }

    $allTouched = $true
    foreach ($ef in $expected) {
        if (-not $filesSet.ContainsKey($ef.ToLowerInvariant())) { $allTouched = $false; break }
    }
    if (-not $allTouched) { continue }

    # Milestone reached.
    $subtask = if ($step.PSObject.Properties['subtask'] -and $step.subtask) { [string]$step.subtask } else { '(no subtask declared)' }
    $expectedList = $expected -join ', '
    $total = $decomp.Count
    $acceptForm = "ACCEPT step $stepNum"
    $reviseForm = "REVISE step ${stepNum}: one-line diagnosis"
    $msg = "VERIFY MILESTONE step $stepNum of $total`n  subtask: $subtask`n  expected_files: $expectedList (all touched)`n  Emit '$acceptForm' to proceed, or '$reviseForm' to repair."
    Write-HookJson @{ additional_context = $msg }
    exit 0
}

exit 0
