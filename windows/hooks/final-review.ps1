# final-review.ps1 - stop hook (Cursor).
#
# ONE end-of-implementation review across six axes (intent, correctness,
# reliability, coverage, anti-slop, wiring). On a clean stop where files
# changed this session, Cursor auto-submits this hook's `followup_message` as
# the next user turn so the model re-audits its whole session diff.
#
# Change detection: `git diff --name-only HEAD` + `git ls-files --others
# --exclude-standard` against the resolved repo root. Zero state on disk.
#
# Bounded:
#   - per-cid reviewed-<cid>.flag: armed when a review is emitted; cleared on
#     the post-review stop (hook-generated last turn or loop_count > 0),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed'.
#
# Always emits valid JSON ({} = no follow-up). Review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
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
$loopLimit = 2
if ($env:FINAL_REVIEW_LOOP_LIMIT) {
    try { $loopLimit = [int]$env:FINAL_REVIEW_LOOP_LIMIT } catch { }
}

$pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
$flag = Join-Path $pendingDir "reviewed-$cid.flag"

# Sweep state older than 7 days from sessions that died before their stop hook.
try {
    Get-ChildItem $pendingDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# One-shot brake: post-review stop clears the flag and ends the loop.
# Orphaned flags (review follow-up never ran) are cleared and we continue.
if (Test-Path $flag) {
    $lastRaw = Get-LastRawUserQueryText $obj
    if (($lastRaw -and (Test-IsHookGeneratedQuery $lastRaw)) -or $loopCount -gt 0) {
        Remove-Item $flag -Force -ErrorAction SilentlyContinue
        Emit-None 'post_review_cleanup'
    }
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    Write-FinalReviewDebug 'stale_flag_cleared'
}

if ($loopCount -ge $loopLimit) { Emit-None 'loop_limit' }

# Review only a clean completion.
if ($status -and $status -ne 'completed') { Emit-None 'no_status' }

# Resolve repo root. No root -> no audit scope -> nothing to review.
$root = Resolve-ProjectRoot $obj
if (-not $root) { Emit-None 'no_root' }

# Confirm git repo at root.
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Emit-None 'no_git' }

# --- collect changed files: tracked diff + untracked new files ----------------
$edited = New-Object System.Collections.Generic.List[string]
foreach ($l in & git -C $root diff HEAD --name-only 2>$null) {
    if ($l) { $edited.Add($l) }
}
foreach ($l in & git -C $root ls-files --others --exclude-standard 2>$null) {
    if ($l) { $edited.Add($l) }
}
if ($edited.Count -eq 0) { Emit-None 'no_diff' }

# Dedupe, normalize to repo-relative forward-slash paths.
$rel = New-Object System.Collections.Generic.List[string]
foreach ($f in $edited) {
    $rp = ConvertTo-FwdPath $f
    if ($rp.StartsWith($root + '/', [System.StringComparison] 'OrdinalIgnoreCase')) {
        $rp = $rp.Substring($root.Length + 1)
    }
    $rp = $rp.TrimStart('/')
    if ($rp -and -not $rel.Contains($rp)) { $rel.Add($rp) }
}
if ($rel.Count -eq 0) { Emit-None 'no_diff' }

# --- review prompt body (md preferred, embedded fallback) ---------------------
$body = ''
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
if (Test-Path -LiteralPath $promptFile) { $body = Get-Content -Raw -LiteralPath $promptFile }
if (-not $body) {
    $body = @'
FINAL REVIEW - audit everything you changed this session and FIX what fails
(do NOT revert the behaviour the user asked for). Run the axes in order.
Emit ONE verdict line per axis, then any fixes:
  axis N <name>: PASS | FIX (<what>) -> <what you did>
Skip axes marked "(skip if ...)". Then stop. No summary paragraph.
  0. Intent trace (run first, outranks all) - tie every diff hunk to ORIGINAL REQUEST.
     Untraceable = hallucinated = revert. Prior-turn hunks stay.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present.
  4. Anti-slop - apply ~/.agents/hooks/anti-slop.md to the session diff.
  5. Wiring completeness - trace user-visible changes to a REAL EFFECT (persist/mutate/render).
  6. Mechanics - N+1, idempotency, txn/rollback, guard clauses, no primitive obsession.
  7. Role-trace (skip if decomposition empty) - every step has verdict, no leakage.
Fix now, re-run tests, then stop.
'@
}
$body = Expand-AgentPaths $body

# --- .scope.json: declarative contract (optional, agent-written at Step 0) ----
$scopePath = Join-Path $root '.scope.json'
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
        # Role-trace (axis 7): decomposition + verifications. Empty = YAGNI rung 1.
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

# --- change-surface metric ----------------------------------------------------
$fileList = ($rel | Select-Object -First 30) -join "`n  "
$uniqueFiles = @($rel | Select-Object -Unique).Count
$surfaceBlock = "Session footprint: $uniqueFiles file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.`n`n"

$msg = "FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop, wiring, mechanics, role-trace (if decomposed). Emit one verdict line per axis (PASS | FIX).`n`n${surfaceBlock}${scopeBlock}${declaredNote}${roleTraceBlock}${intentBlock}Files you changed this session:`n  $fileList`n`n$body"

# Arm the brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-FinalReviewDebug 'emitted'
Write-HookJson @{ followup_message = $msg }
exit 0
