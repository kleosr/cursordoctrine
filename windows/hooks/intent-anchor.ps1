# intent-anchor.ps1 - postToolUse: one-shot nudge to fill the .scope.json contract.
#
# The .scope.json contract divides labor: hook owns prompt + files[] +
# verifications[]; agent owns intent (Step 0 restatement) + acceptance (real
# done-check) + decomposition. When the agent skips its half — leaves intent
# empty and/or acceptance at the default seed — the contract is degraded:
# final-review's intent trace falls back to the raw prompt, and the acceptance
# bar shown is generic rather than task-specific.
#
# This hook fires AT MOST ONCE per conversation_id, on the first postToolUse
# where .scope.json exists and either field is still empty/default. It emits
# an INTENT ANCHOR reminder as additional_context so the agent fills the
# contract before going further. The hook never writes intent or acceptance;
# it just surfaces the gap.
#
# The per-cid flag (intent-anchored-<cid>.flag) is armed BEFORE emitting, so a
# crash can't re-fire and the agent won't see the nudge twice. If intent AND
# acceptance are both already filled/customized when the hook first runs, the
# flag is armed silently (no emission) so we never bug this cid again.
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

# One-shot per cid. Once the flag exists we never fire again for this convo.
$pendingDir = Join-Path $HOME '.cursor\.hooks-pending'
$flag = Join-Path $pendingDir "intent-anchored-$cid.flag"
if (Test-Path $flag) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path $scopePath)) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

$intent = ''
if ($sj.PSObject.Properties['intent']) { $intent = [string]$sj.intent }
$acceptance = ''
if ($sj.PSObject.Properties['acceptance']) { $acceptance = [string]$sj.acceptance }
$defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

$intentEmpty = [string]::IsNullOrWhiteSpace($intent)
$acceptanceDefault = ($acceptance -ieq $defaultAcceptance)

# Arm the flag BEFORE any emission so a crash can't re-fire. This also covers
# the "both already filled" case: arm silently and exit.
New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

if (-not ($intentEmpty -or $acceptanceDefault)) { exit 0 }

$prompt = ''
if ($sj.PSObject.Properties['prompt']) { $prompt = [string]$sj.prompt }

$msg = 'INTENT ANCHOR: the .scope.json contract is incomplete. The harness can only re-inject what you write — fill the agent-owned fields now:'
if ($intentEmpty) {
    $msg += "`n  - intent: empty. Write your one-line Step 0 restatement of the task (NOT the verbatim prompt)."
} else {
    $msg += "`n  - intent: OK"
}
if ($acceptanceDefault) {
    $msg += "`n  - acceptance: still the default seed. Sharpen it to this task's real done-check (e.g. specific test command, specific behavior that must hold)."
} else {
    $msg += "`n  - acceptance: OK"
}
$msg += "`n`nCurrent prompt: $prompt`nNext edit won't re-trigger this nudge — the harness arms the flag once per session."

Write-HookJson @{ additional_context = $msg }
exit 0
