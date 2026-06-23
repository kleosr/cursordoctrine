# final-review.ps1 - stop hook (Cursor).
#
# ONE end-of-implementation review across eight axes (0 intent, 1 correctness,
# 2 reliability, 3 coverage, 4 anti-slop, 5 wiring, 6 mechanics, 7 role-trace).
# On a clean stop where files changed this session, Cursor auto-submits this
# hook's `followup_message` as the next user turn so the model re-audits its
# whole session diff.
#
# Change detection (two paths):
#   doctrine project (.scope.json present): `files[]` is the authoritative
#       per-session edit surface (maintained by scope-refresh on every
#       afterFileEdit). Empty files[] = agent made no session edits = no review
#       (read-only turns don't fire). This is the root fix: previously git diff
#       HEAD was preferred, which counted pre-existing uncommitted files the
#       agent only READ as "changed this session".
#   non-doctrine (no .scope.json): `git diff --name-only HEAD` +
#       `git ls-files --others --exclude-standard` (unchanged).
#
# Verify-revise loop: the brake flag stores the changed-file COUNT at review
# time. On the post-review stop, if the count CHANGED (the agent revised based
# on the review), the review RE-FIRES with the new diff. If the count is the
# SAME (the agent accepted, no fixes), the flag clears and the loop ends.
# This implements the Trinity verify-revise-reverify cycle: review → fix →
# re-review until the diff stabilizes. Bounded by loop_limit (default 3).
#
# Review prompt lives in final-review.md (REQUIRED — no stale fallback). If
# missing, emits an error message instead of a degraded review.
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.
# Debug: FINAL_REVIEW_DEBUG=1 logs exit reason to ~/.cursor/.hooks-pending/last-final-review.log

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

function Emit-None([string]$Reason) {
    if ($Reason) { Write-FinalReviewDebug $Reason }
    '{}'; exit 0
}

if ($env:HOOKS_ENFORCE -eq '0' -or $env:FINAL_REVIEW_ENFORCE -eq '0') { Emit-None 'kill_switch' }

$obj = Read-HookStdinJson
if (-not $obj) { Emit-None 'no_input' }

$status = ''
if ($obj.PSObject.Properties['status']) { $status = [string]$obj.status }
$cid = Get-SafeConversationId $obj

$loopCount = 0
if ($obj.PSObject.Properties['loop_count']) {
    try { $loopCount = [int]$obj.loop_count } catch { $loopCount = 0 }
}
$loopLimit = 3
if ($env:FINAL_REVIEW_LOOP_LIMIT) {
    try { $loopLimit = [int]$env:FINAL_REVIEW_LOOP_LIMIT } catch { }
}

$pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
$flag = Join-Path $pendingDir "reviewed-$cid.flag"

# Review only a clean completion.
if ($status -and $status -ne 'completed') { Emit-None 'no_status' }

# Resolve repo root early — needed by the verify-revise brake.
$root = Resolve-ProjectRoot $obj
if (-not $root) { Emit-None 'no_root' }

# Sweep state older than 7 days from sessions that died before their stop hook.
try {
    Get-ChildItem $pendingDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# --- verify-revise brake: compare current diff to review-time diff ------------
# The flag stores the changed-file count at review time. On the post-review
# stop, if the count CHANGED (agent revised), re-review the new diff. If SAME
# (agent accepted), clear and end. Orphaned flags from missed follow-ups are
# cleared. This implements Trinity's verify-revise-reverify cycle.
#
# The diff count is computed here (before the full git section below) so the
# brake can compare early and exit fast.
function Get-DiffCount([string]$repoRoot) {
    $sp = Join-Path $repoRoot '.scope.json'
    if (Test-Path -LiteralPath $sp) {
        # Doctrine project: files[] is the per-session edit surface.
        # Empty/missing files[] → 0 (agent made no session edits).
        try {
            $sj2 = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
            if ($sj2.PSObject.Properties['files'] -and $sj2.files) {
                return @($sj2.files | Where-Object { $_ -and "$_".Trim() -and "$_" -notmatch '^\s*<' -and "$_" -ine '.scope.json' }).Count
            }
        } catch { }
        return 0
    }
    # Non-doctrine fallback: git diff + untracked.
    & git -C $repoRoot rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $c = @(& git -C $repoRoot diff HEAD --name-only 2>$null).Count
        $c += @(& git -C $repoRoot ls-files --others --exclude-standard 2>$null).Count
        return $c
    }
    return 0
}

if (Test-Path $flag) {
    $lastRaw = Get-LastRawUserQueryText $obj
    if (($lastRaw -and (Test-IsHookGeneratedQuery $lastRaw)) -or $loopCount -gt 0) {
        # Post-review stop. Check if the agent revised (diff changed).
        $prevCount = 0
        try { $prevCount = [int]((Get-Content $flag -Raw -ErrorAction SilentlyContinue).Trim()) } catch { }
        $curCount = Get-DiffCount $root
        if ($curCount -ne $prevCount -and $loopCount -lt $loopLimit) {
            # Agent revised → re-review the new diff. Fall through to emit.
            Write-FinalReviewDebug "re_review (prev=$prevCount cur=$curCount loop=$loopCount)"
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
        } else {
            # Agent accepted (same diff) or loop limit hit → end.
            Remove-Item $flag -Force -ErrorAction SilentlyContinue
            Emit-None 'post_review_cleanup'
        }
    }
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    Write-FinalReviewDebug 'stale_flag_cleared'
}

if ($loopCount -ge $loopLimit) { Emit-None 'loop_limit' }

# --- collect changed files (.scope.json files[] primary; git fallback) ---------
# Priority:
#   1. .scope.json present → files[] is the authoritative per-session edit
#      surface (maintained by scope-refresh on every afterFileEdit). Empty
#      files[] → agent made no session edits → no_diff (read-only turns don't
#      fire a review). Root fix: previously git diff HEAD was preferred, which
#      counted pre-existing uncommitted files the agent only READ as "changed
#      this session".
#   2. No .scope.json (non-doctrine project) → git diff HEAD + untracked,
#      unchanged from before.
$rel = New-Object System.Collections.Generic.List[string]
$diffStat = ''
$isGitRepo = $false
$scopePath = Join-Path $root '.scope.json'

if (Test-Path -LiteralPath $scopePath) {
    # Doctrine project: files[] is the authoritative session-edit surface.
    try {
        $sjSc = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sjSc.PSObject.Properties['files'] -and $sjSc.files) {
            foreach ($f in $sjSc.files) {
                $s = [string]$f
                if (-not $s -or $s -match '^\s*<' -or $s -match '^\s*$') { continue }
                $rp = $s.Replace('\', '/').TrimStart('/')
                if ($rp -and $rp -ine '.scope.json' -and -not $rel.Contains($rp)) { $rel.Add($rp) }
            }
        }
    } catch { }
    # Diff-stat evidence scoped to the session surface, not the whole tree.
    if ($rel.Count -gt 0) {
        & git -C $root rev-parse --git-dir 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $isGitRepo = $true
            $statArgs = @('-C', $root, 'diff', 'HEAD', '--stat') + $rel
            $diffStat = (& git @statArgs 2>$null) -join "`n"
        }
    }
} else {
    # Non-doctrine fallback: git diff HEAD + untracked (whole tree).
    & git -C $root rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $isGitRepo = $true
        $edited = New-Object System.Collections.Generic.List[string]
        foreach ($l in & git -C $root diff HEAD --name-only 2>$null) {
            if ($l) { $edited.Add($l) }
        }
        foreach ($l in & git -C $root ls-files --others --exclude-standard 2>$null) {
            if ($l) { $edited.Add($l) }
        }
        # Capture diff stat for evidence injection.
        $diffStat = (& git -C $root diff HEAD --stat 2>$null) -join "`n"
        foreach ($f in $edited) {
            $rp = ConvertTo-FwdPath $f
            if ($rp.StartsWith($root + '/', [System.StringComparison] 'OrdinalIgnoreCase')) {
                $rp = $rp.Substring($root.Length + 1)
            }
            $rp = $rp.TrimStart('/')
            if ($rp -and -not $rel.Contains($rp)) { $rel.Add($rp) }
        }
    }
}

if ($rel.Count -eq 0) { Emit-None 'no_diff' }

# --- review prompt body (md REQUIRED — no stale fallback) ---------------------
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
if (-not (Test-Path -LiteralPath $promptFile)) {
    # No fallback. The .md is part of the install. If missing, the install is
    # broken — tell the agent to fix it instead of running a degraded review.
    $msg = "FINAL REVIEW: The review template (~/.agents/hooks/final-review.md) is missing. Your cursordoctrine install is incomplete. Run: npx cursordoctrine install"
    New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -LiteralPath $flag -Value $uniqueFiles -ErrorAction SilentlyContinue
    Write-HookJson @{ followup_message = $msg }
    exit 0
}
$body = Get-Content -Raw -LiteralPath $promptFile
if (-not $body) { Emit-None 'empty_prompt' }
$body = Expand-AgentPaths $body

# --- .scope.json: declarative contract (optional, agent-written at Step 0) ----
# $scopePath already resolved above (change-surface block).
$scopeBlock = ''
$declaredNote = ''
$roleTraceBlock = ''
$scopePrompt = ''
$scopeIntent = ''
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sj.PSObject.Properties['prompt'] -and $sj.prompt) {
            $scopePrompt = [string]$sj.prompt
        }
        if ($sj.PSObject.Properties['intent'] -and $sj.intent) {
            $scopeIntent = [string]$sj.intent
        }
        if ($sj.PSObject.Properties['acceptance'] -and $sj.acceptance) {
            $scopeBlock = "Declared acceptance: $($sj.acceptance)`n`n"
        }
        if ($sj.PSObject.Properties['files'] -and $sj.files) {
            $declared = @($sj.files | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\s*<' } |
                           ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') } |
                           Select-Object -Unique)
            if ($declared.Count -gt 0) {
                $touchedSet = @{}
                foreach ($f in ($rel | Where-Object { $_ -ieq '.scope.json' -eq $false })) {
                    $touchedSet[$f.ToLowerInvariant()] = $true
                }
                $declaredSet = @{}
                foreach ($f in $declared) { $declaredSet[$f.ToLowerInvariant()] = $true }
                $missed = @($declared | Where-Object { -not $touchedSet.ContainsKey($_.ToLowerInvariant()) })
                $extra  = @($rel     | Where-Object { -not($_ -ieq '.scope.json') -and -not $declaredSet.ContainsKey($_.ToLowerInvariant()) })
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add("Declared scope: $($declared.Count) file(s); git sees $($rel.Count) touched.")
                if ($missed.Count -gt 0) {
                    $lines.Add("  Declared but NOT touched ($($missed.Count)): " + (($missed | Select-Object -First 8) -join ', '))
                }
                if ($extra.Count -gt 0) {
                    $lines.Add("  Touched but NOT declared ($($extra.Count)): " + (($extra | Select-Object -First 8) -join ', '))
                }
                if ($missed.Count -eq 0 -and $extra.Count -eq 0) {
                    $lines.Add("  (matches declared scope)")
                }
                $declaredNote = ($lines -join "`n") + "`n`n"
            }
        }
        # Role-trace (axis 7): decomposition + verifications. Empty
        # decomposition is YAGNI rung 1 ONLY for a trivial one-liner (<=1 file);
        # for a multi-file task an empty decomposition is a CONTRACT GAP that
        # FAILs axis 7 (the doctrine requires a plan for multi-step work).
        if ($sj.PSObject.Properties['decomposition'] -and $sj.decomposition) {
            $decomp = @($sj.decomposition)
            $verifs = @()
            if ($sj.PSObject.Properties['verifications'] -and $sj.verifications) { $verifs = @($sj.verifications) }
            $verdictByStep = @{}
            foreach ($v in $verifs) {
                if ($v -and $v.PSObject.Properties['step']) {
                    try { $verdictByStep[[int]$v.step] = [string]$v.verdict } catch { }
                }
            }
            $touchedSetRt = @{}
            foreach ($f in $rel) { if ($f -ine '.scope.json') { $touchedSetRt[$f.ToLowerInvariant()] = $true } }
            $allExpected = @{}
            foreach ($step in $decomp) {
                if (-not $step -or -not $step.PSObject.Properties['step']) { continue }
                if ($step.PSObject.Properties['expected_files'] -and $step.expected_files) {
                    foreach ($ef in $step.expected_files) {
                        $allExpected[([string]$ef).Replace('\', '/').TrimStart('/').ToLowerInvariant()] = $true
                    }
                }
            }
            $leakage = @()
            foreach ($f in $rel) {
                if ($f -ine '.scope.json' -and -not $allExpected.ContainsKey($f.ToLowerInvariant())) { $leakage += $f }
            }
            $rtLines = New-Object System.Collections.Generic.List[string]
            $rtLines.Add("Decomposition: $($decomp.Count) step(s); verdicts recorded: $($verdictByStep.Count).")
            foreach ($step in $decomp) {
                if (-not $step -or -not $step.PSObject.Properties['step']) { continue }
                try { $sn = [int]$step.step } catch { continue }
                $subtask = if ($step.PSObject.Properties['subtask'] -and $step.subtask) { [string]$step.subtask } else { '(no subtask)' }
                $expected = @()
                if ($step.PSObject.Properties['expected_files'] -and $step.expected_files) {
                    $expected = @($step.expected_files) | ForEach-Object { ([string]$_).Replace('\', '/').TrimStart('/') }
                }
                $missing = @($expected | Where-Object { -not $touchedSetRt.ContainsKey(([string]$_).ToLowerInvariant()) })
                $verdict = if ($verdictByStep.ContainsKey($sn)) { $verdictByStep[$sn] } else { '(no verdict)' }
                $status = if ($missing.Count -gt 0) { "missing $($missing.Count) expected" }
                          elseif ($verdict -eq 'ACCEPT') { 'ACCEPTED' }
                          elseif ($verdict -eq 'REVISE') { 'REVISE open' }
                          else { 'touched, awaiting verdict' }
                $rtLines.Add("  step $sn [$status] - $subtask")
            }
            if ($leakage.Count -gt 0) {
                $rtLines.Add("  Touched but NOT in any step's expected_files ($($leakage.Count)): " + (($leakage | Select-Object -First 8) -join ', '))
            }
            $roleTraceBlock = ($rtLines -join "`n") + "`n`n"
        } elseif ($rel.Count -ge 2) {
            # CONTRACT GAP: multi-file task with NO decomposition declared.
            # Axis 7 FAILs (not SKIP) — the doctrine requires decomposition for
            # any multi-step / multi-file change. $rel.Count is the real
            # session-edit surface (excludes .scope.json + placeholders).
            $gapLines = New-Object System.Collections.Generic.List[string]
            $gapLines.Add("Decomposition: EMPTY for a $($rel.Count)-file task. The doctrine requires a decomposition[] for any multi-step / multi-file change.")
            $gapLines.Add("  Declare it now: each entry { step (int), subtask (one-line), expected_files (array of paths) }.")
            $gapLines.Add("  Axis 7 (role-trace) will FAIL until decomposition is declared. Trivial one-liners (<=1 file) are the only SKIP.")
            $roleTraceBlock = ($gapLines -join "`n") + "`n`n"
        }
    } catch { }
}

# --- intent trace: intent primary, prompt as source, transcript fallback -------
$userQuery = $scopeIntent
if ([string]::IsNullOrWhiteSpace($userQuery)) { $userQuery = $scopePrompt }
if ([string]::IsNullOrWhiteSpace($userQuery)) { $userQuery = Get-LastUserQuery $obj }
$intentBlock = ''
if ($userQuery) {
    $intentBlock = "ORIGINAL REQUEST (intent trace):`n---`n$userQuery`n---`n"
    if ($scopeIntent -and $scopePrompt) {
        $intentBlock += "User prompt (source): $scopePrompt`n`n"
    } else {
        $intentBlock += "`n"
    }
}
# CONTRACT GAP: intent never written (empty or stale [DRAFT] from a legacy
# install). Axis 0 FAILs until the agent writes a one-line Step 0 restatement
# of THIS task in its own words (clearer than the verbatim prompt).
if ([string]::IsNullOrWhiteSpace($scopeIntent) -or $scopeIntent -match '^\[DRAFT\]') {
    $intentGap = "CONTRACT GAP: .scope.json intent is empty/[DRAFT] - the agent never wrote its Step 0 restatement. Axis 0 (intent trace) will FAIL until you write a one-line restatement of THIS task in your own words (clearer/better than the verbatim prompt, NOT a copy).`n`n"
    $intentBlock = $intentGap + $intentBlock
}

# --- change-surface metric ----------------------------------------------------
$fileList = ($rel | Select-Object -First 30) -join "`n  "
$uniqueFiles = @($rel | Select-Object -Unique).Count
$surfaceBlock = "Session footprint: $uniqueFiles file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.`n"
# Inject diff stat as evidence when git is available.
if ($diffStat) {
    $statTrimmed = ($diffStat -split "`n" | Select-Object -Last 1).Trim()
    $surfaceBlock += "Diff: $statTrimmed`n"
}
$surfaceBlock += "`n"

$msg = "FINAL REVIEW (end of implementation). Emit a structured bullet report (one line per axis), then fix anything that fails. See the report template below.`n`n${surfaceBlock}${scopeBlock}${declaredNote}${roleTraceBlock}${intentBlock}Files you changed this session:`n  $fileList`n`n$body"

# Arm the brake: store the current changed-file count so the post-review stop
# can detect whether the agent revised (count changed) or accepted (same).
New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
Set-Content -LiteralPath $flag -Value $uniqueFiles -ErrorAction SilentlyContinue

Write-FinalReviewDebug 'emitted'
Write-HookJson @{ followup_message = $msg }
exit 0
