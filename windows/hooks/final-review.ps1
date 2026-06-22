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
#   - per-cid reviewed-<cid>.flag: the stop AFTER the review clears it and
#     ends the loop (one review per implementation),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed'.
#
# Always emits valid JSON ({} = no follow-up). Review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

function Emit-None { '{}'; exit 0 }

if ($env:HOOKS_ENFORCE -eq '0' -or $env:FINAL_REVIEW_ENFORCE -eq '0') { Emit-None }

$obj = Read-HookStdinJson
if (-not $obj) { Emit-None }

$status = ''
if ($obj.PSObject.Properties['status']) { $status = [string]$obj.status }
$cid = Get-SafeConversationId $obj

$pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
$flag = Join-Path $pendingDir "reviewed-$cid.flag"

# Sweep state older than 7 days from sessions that died before their stop hook.
try {
    Get-ChildItem $pendingDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# One-shot brake: the previous stop emitted the review; clear it and end the loop.
if (Test-Path $flag) {
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    Emit-None
}

# Review only a clean completion.
if ($status -and $status -ne 'completed') { Emit-None }

# Resolve repo root. No root -> no audit scope -> nothing to review.
$root = Resolve-ProjectRoot $obj
if (-not $root) { Emit-None }

# Confirm git repo at root.
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Emit-None }

# --- collect changed files: tracked diff + untracked new files ----------------
$edited = New-Object System.Collections.Generic.List[string]
foreach ($l in & git -C $root diff HEAD --name-only 2>$null) {
    if ($l) { $edited.Add($l) }
}
foreach ($l in & git -C $root ls-files --others --exclude-standard 2>$null) {
    if ($l) { $edited.Add($l) }
}
if ($edited.Count -eq 0) { Emit-None }

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
if ($rel.Count -eq 0) { Emit-None }

# --- review prompt body (md preferred, embedded fallback) ---------------------
$body = ''
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
if (Test-Path -LiteralPath $promptFile) { $body = Get-Content -Raw -LiteralPath $promptFile }
if (-not $body) {
    $body = @'
FINAL REVIEW - audit everything you changed this session and FIX what fails
(do NOT revert the behaviour the user asked for):
  0. Intent trace - tie every diff hunk back to the ORIGINAL REQUEST above.
     Anything untraceable is a hallucinated requirement: revert it. Runs FIRST.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present;
     no tautological tests.
  4. Anti-slop - read ~/.agents/hooks/anti-slop.md (single source of truth) and apply
     all items to the session diff.
  5. Wiring completeness - for every user-visible behavior you added/changed,
     trace its execution path to a REAL EFFECT (persist, mutate, call, render).
     A dead end is slop: handleSubmit that does not persist, an endpoint no caller
     invokes, a stub/TODO/console.log standing in for the effect. Wire it now or
     remove the dead half; mark later-stubs with TODO(wire):.
Fix now, re-run tests, then stop. If an axis is clean, say so in one line.
'@
}
$body = Expand-AgentPaths $body

# --- .scope.json: declarative contract (optional, agent-written at Step 0) ----
# If present, prefer its intent for axis 0 (sharper than transcript extraction)
# and compute the blast-radius diff: declared vs touched.
$scopePath = Join-Path $root '.scope.json'
$scopeBlock = ''
$declaredNote = ''
$scopeIntent = ''
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
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
                # The contract file itself isn't a real edit; exclude from the
                # touched set so it doesn't read as "touched but not declared".
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
    } catch { }   # malformed .scope.json -> ignore, fall back to transcript
}

# --- intent trace: prefer .scope.json's intent, fall back to transcript --------
$userQuery = $scopeIntent
if ([string]::IsNullOrWhiteSpace($userQuery)) { $userQuery = Get-LastUserQuery $obj }
$intentBlock = ''
if ($userQuery) {
    $intentBlock = "ORIGINAL REQUEST (intent trace):`n---`n$userQuery`n---`n`n"
}

# --- change-surface metric ----------------------------------------------------
$fileList = ($rel | Select-Object -First 30) -join "`n  "
$uniqueFiles = @($rel | Select-Object -Unique).Count
$surfaceBlock = "Session footprint: $uniqueFiles file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.`n`n"

$msg = "FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop.`n`n${surfaceBlock}${scopeBlock}${declaredNote}${intentBlock}Files you changed this session:`n  $fileList`n`n$body"

# Arm the brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-HookJson @{ followup_message = $msg }
exit 0
