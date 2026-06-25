# intent-anchor.ps1 - postToolUse: persistent nudge to fill the .scope.json contract.
#
# The .scope.json contract divides labor: hook owns prompt + files[] +
# verifications[]; agent owns intent (Step 0 restatement) + acceptance (real
# done-check) + decomposition. When the agent skips its half — leaves intent
# empty and/or acceptance at the default seed — the contract is degraded:
# final-review's intent trace falls back to the raw prompt, and the acceptance
# bar shown is generic rather than task-specific.
#
# This hook re-fires when the contract is still incomplete (empty intent and/or
# default acceptance) AND either this conversation has never been nudged
# (lastCount -lt 0) OR files[] has grown since the last nudge.
# The per-cid flag stores the files[] count at last fire; if files[] hasn't
# grown, the hook stays silent (no new work to anchor against). Once intent AND
# acceptance are both filled, the hook goes silent permanently for this cid.
# This replaces the old one-shot-per-session design: a single ignored nudge
# left intent empty for the entire session. Now every new edit re-surfaces
# the gap until the agent fills it.
#
# Disable: HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:INTENT_ANCHOR_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$cid = Get-SafeConversationId $obj
$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

# Per-cid throttle: the flag stores "filesCount:nudgeCount". Re-fire only when
# files[] has grown since the last nudge AND we haven't exceeded the nudge cap
# (default 99999 — effectively unlimited). History: the cap was 3 (too low: a
# 10-file task went permanently silent after 3 ignored nudges and the contract
# stayed broken for the whole session), then 8 (still exhausted mid-session on
# a 30-file audit, leaving intent empty with zero further signal). A contract
# that can be emptied by an ignoring agent is worse than a noisy one, so the cap
# is now effectively unbounded. Re-nudges still only fire on NEW file edits
# (avoids spamming when nothing changes); the final-review axis 0 FAIL is the
# hard backstop at stop time. Override: INTENT_ANCHOR_NUDGE_CAP.
$nudgeCap = 99999
if ($env:INTENT_ANCHOR_NUDGE_CAP) {
    try { $nudgeCap = [int]$env:INTENT_ANCHOR_NUDGE_CAP } catch { }
}
$pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
$flag = Join-Path $pendingDir "intent-anchored-$cid.flag"

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path $scopePath)) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

$filesCount = 0
if ($sj.PSObject.Properties['files'] -and $sj.files) { $filesCount = @($sj.files).Count }

$lastCount = -1
$nudgeCount = 0
if (Test-Path $flag) {
    try {
        $flagData = (Get-Content $flag -Raw -ErrorAction SilentlyContinue).Trim()
        $parts = $flagData -split ':'
        if ($parts.Count -ge 1) { $lastCount = [int]$parts[0] }
        if ($parts.Count -ge 2) { $nudgeCount = [int]$parts[1] }
    } catch { }
}

$intent = ''
if ($sj.PSObject.Properties['intent']) { $intent = [string]$sj.intent }
$acceptance = ''
if ($sj.PSObject.Properties['acceptance'] -and $sj.acceptance -is [string]) { $acceptance = [string]$sj.acceptance }
$defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

$intentEmpty = [string]::IsNullOrWhiteSpace($intent)
$intentDraft = $intent -match '^\[DRAFT\]'
$acceptanceDefault = [string]::IsNullOrWhiteSpace($acceptance) -or ($acceptance -ieq $defaultAcceptance)

# Both filled → contract complete. Store count and stay silent permanently.
if (-not ($intentEmpty -or $intentDraft -or $acceptanceDefault)) {
    New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -LiteralPath $flag -Value "${filesCount}:0" -ErrorAction SilentlyContinue
    exit 0
}

# Contract incomplete but no new files since last nudge → stay silent.
# Exception: lastCount -lt 0 means never nudged this cid — first postToolUse fires.
if ($lastCount -ge 0 -and $filesCount -le $lastCount) { exit 0 }

# Contract incomplete but nudge cap exceeded → stay silent (stop pestering).
if ($nudgeCount -ge $nudgeCap) { exit 0 }

# Contract incomplete AND new files since last nudge AND under cap → emit.
$nudgeCount++
# Store count BEFORE emitting so a crash can't re-fire for the same set.
New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
Set-Content -LiteralPath $flag -Value "${filesCount}:${nudgeCount}" -ErrorAction SilentlyContinue

$prompt = ''
if ($sj.PSObject.Properties['prompt']) { $prompt = [string]$sj.prompt }

$msg = 'INTENT ANCHOR: the .scope.json contract is incomplete. The harness can only re-inject what you write — fill the agent-owned fields now:'
if ($intentEmpty) {
    $msg += "`n  - intent: empty. Write your one-line Step 0 restatement of the task (NOT the verbatim prompt)."
} elseif ($intentDraft) {
    $msg += "`n  - intent: still a [DRAFT] copy of the prompt. Rewrite it in your own words — what the user actually wants to achieve and why. Remove the [DRAFT] prefix."
} else {
    $msg += "`n  - intent: OK"
}
if ($acceptanceDefault) {
    $msg += "`n  - acceptance: still the default seed. Sharpen it to this task's real done-check (e.g. specific test command, specific behavior that must hold)."
} else {
    $msg += "`n  - acceptance: OK"
}
$msg += "`n`nCurrent prompt: $prompt`nThis nudge re-fires on each new file edit until the contract is filled (nudge $nudgeCount of $nudgeCap)."

Write-HookJson @{ additional_context = $msg }
exit 0
