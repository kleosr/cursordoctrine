# intent-anchor.ps1 - postToolUse "thin intent compilation" anchor (Cursor).
#
# Counteracts Salience Dilution: the failure mode where the agent's original
# intent erodes as the conversation fills with code, logs and errors, until the
# token of the original request is a rounding error against the recent history
# and the agent drifts ("forgets" symmetry, colors, the .scope.json it wrote at
# prompt 1). Two jobs, both on the FIRST tool boundary of each turn (per-turn
# latch intent-injected-<cid>.flag, armed here, cleared at every stop):
#
#   1. RE-INJECT .scope.json (the core anti-dilution move): read the contract
#      (intent + files + acceptance) and stash it in the feedback bus so
#      post-tool-use.ps1 delivers it as additional_context at the next tool
#      boundary. This puts the contract back in the model's attentional focus
#      at the START of each turn's work, before edits pile up and dilute the
#      original intent. Works UNCONDITIONALLY - no transcript needed.
#
#   2. AUTO-CREATE / REGENERATE .scope.json: when the current <user_query>
#      differs from the contract on disk (no contract yet, OR _intent_hash
#      mismatch), the hook WRITES a scaffold to the REPO ROOT: intent locked
#      from the prompt, files/acceptance as TODO placeholders the agent
#      refines. This is the user-requested behavior: every new prompt ->
#      a fresh .scope.json the agent works from. Fixed vs the broken 0.4.4
#      build: never writes to $HOME (bails if no real root resolves -> no
#      ghost files), and regenerates on prompt CHANGE not just on absence.
#   3. RE-INJECT on same-prompt turns: when the query is unchanged (contract
#      already current), the hook re-injects the existing contract into the
#      feedback bus so it stays in the model's attentional focus each turn.
#
# Why postToolUse, not afterFileEdit: afterFileEdit only fires AFTER an edit
# exists, and Cursor has no preToolUse for file edits. postToolUse fires after
# EVERY tool (Read/Glob/Bash/Write/...), so its first fire of a turn is the
# earliest moment the agent has begun working - typically right after the first
# Read/Glob, before any edit. Best available injection point for "before files".
#
# Once per turn: latch armed on first fire, cleared UNCONDITIONALLY at every
# stop (final-review.ps1). Cannot strand silenced mid-session (that was the
# 0.4.0 bug). Registered first in the postToolUse array so it appends to the
# feedback bus before post-tool-use.ps1 drains it (same-tool delivery; if an
# updated install orders it after, delivery slips one tool - still correct).
#
# Advisory only: never blocks, never reads the diff, ALWAYS exits 0. Appends to
# the shared feedback-<cid>.txt bus. Disable: HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:INTENT_ANCHOR_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$cid = Get-SafeConversationId $obj
$pendingDir = Get-HooksPendingDir
$latch    = Join-Path $pendingDir "intent-injected-$cid.flag"
$hashFile = Join-Path $pendingDir "last-query-$cid.hash"

# Already injected this turn -> quiet. Latch cleared at every stop.
if (Test-Path $latch) { exit 0 }

# --- current request (best-effort; absent in sandboxed runs) -----------------
$currentQuery = Get-LastUserQuery $obj
$hasQuery = -not [string]::IsNullOrWhiteSpace($currentQuery)

$currentHash = ''
$promptChanged = $false
if ($hasQuery) {
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($currentQuery)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $currentHash = -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    $prevHash = ''
    if (Test-Path $hashFile) { $prevHash = (Get-Content $hashFile -Raw -ErrorAction SilentlyContinue).Trim() }
    $promptChanged = ($currentHash -ne $prevHash)
}

# --- repo root (same resolution as scope-gate-audit.ps1) ---------------------
# Resolve cwd -> workspace_roots -> CURSOR_PROJECT_DIR. We do NOT fall back to
# $HOME: writing .scope.json into $HOME was the 0.4.4 "ghost file" bug. If we
# cannot resolve a real project root, the hook stays silent (no scaffold, no
# demand) rather than litter the user's home directory.
$root = ''
$cands = @()
if ($obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
if ($obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
foreach ($c in $cands) { $f = ConvertTo-FwdPath $c; if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break } }
if (-not $root -and $env:CURSOR_PROJECT_DIR) {
    $cpd = $env:CURSOR_PROJECT_DIR.Replace('\', '/').TrimEnd('/')
    if (Test-Path -LiteralPath $cpd) { $root = $cpd }
}
# No $HOME fallback. If we still have no root, bail (cannot know where to write).
if (-not $root) { exit 0 }

# --- read the existing contract (if any) -------------------------------------
$scopeExists = $false
$scopeIntent = ''
$scopeAcceptance = ''
$scopeFiles = ''
$scopeStale = $false   # true if the on-disk contract predates the current query
$scopePath = Join-Path $root '.scope.json'
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sj.intent)     { $scopeIntent = [string]$sj.intent }
        if ($sj.acceptance) { $scopeAcceptance = [string]$sj.acceptance }
        if ($sj.files)      { $scopeFiles = ($sj.files -join ', ') }
        $scopeExists = $true
        # The contract is "stale" if its recorded intent hash != current query
        # hash. We persist the query hash inside .scope.json under _intent_hash
        # so staleness survives even if last-query-<cid>.hash was swept.
        if ($hasQuery -and $sj.PSObject.Properties['_intent_hash']) {
            $scopeStale = ([string]$sj._intent_hash -ne $currentHash)
        }
    } catch { $scopeExists = $false }   # malformed JSON -> treat as missing
}

# --- auto-create / regenerate .scope.json (the 0.4.4 behavior, fixed) --------
# The user wants: every NEW prompt -> a fresh .scope.json the agent works from.
# So we WRITE the scaffold when (a) there is no valid contract, OR (b) the
# contract on disk is stale (its _intent_hash != current query hash). Intent is
# locked from the current <user_query>; files/acceptance are TODO placeholders
# the agent refines. Fixed vs 0.4.4:
#   - NEVER writes to $HOME (bail above if no real root) -> no ghost files.
#   - Regenerates on prompt CHANGE, not just on absence -> "each prompt, new file".
#   - Records _intent_hash so staleness is self-contained in the file.
$regenerated = $false
$shouldWrite = $hasQuery -and (-not $scopeExists -or $scopeStale)
if ($shouldWrite) {
    try {
        $scaffold = [ordered]@{
            intent        = $currentQuery
            files         = @('<TODO: list files you will touch>')
            acceptance    = '<TODO: the one deterministic check that decides done>'
            allow_growth  = $false
            _intent_hash  = $currentHash
            _generated_by = 'intent-anchor hook'
        }
        $json = $scaffold | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
        $scopeIntent     = $currentQuery
        $scopeAcceptance = '<TODO: the one deterministic check that decides done>'
        $scopeFiles      = '<TODO: list files you will touch>'
        $scopeExists     = $true
        $scopeStale      = $false
        $regenerated     = $true
    } catch { }   # write failed (perms / locked) -> fall through to demand msg
}

# --- compose the anchor message ---------------------------------------------
# Three states: regenerated this turn (new prompt), no contract (and no query
# to scaffold from), or re-injecting an existing current contract.
$queryLine = if ($hasQuery) { $currentQuery } else { '(current request unavailable - no transcript in this event)' }

if ($regenerated) {
    $msg = @"
INTENT ANCHOR (scope regenerated) - .scope.json written for this prompt.

  intent:     $scopeIntent
  files:      $scopeFiles
  acceptance: $scopeAcceptance

The hook wrote a fresh scaffold to $scopePath from your current request. intent
is locked from what you just asked. Fill the TODO placeholders with the real
files you will touch and the deterministic acceptance check, THEN proceed. This
contract will be re-injected every turn until your request changes again.
"@
} elseif (-not $scopeExists) {
    $msg = @"
INTENT ANCHOR (pre-compile) - no .scope.json found in $root, and the current
request was unavailable to scaffold from.

Current request:
  $queryLine

Write .scope.json in the repo root yourself:
  intent:     one operational sentence (what is strictly necessary)
  files:      the exact files you will touch
  acceptance: the one deterministic check that decides done
"@
} else {
    # Contract exists and matches the current prompt -> re-inject it.
    $driftNote = if ($hasQuery) {
        "Every edit this turn must advance intent and stay inside files. acceptance is the bar for done."
    } else {
        "(request unavailable to diff against - re-injecting the contract as-is.)"
    }
    $msg = @"
INTENT ANCHOR (re-injected this turn from .scope.json) - your contract. Do not drift from it.

  intent:     $scopeIntent
  files:      $scopeFiles
  acceptance: $scopeAcceptance

$driftNote If a constraint above conflicts with what you are about to do, stop
and reconcile - the contract outranks momentum.
"@
}

# --- stash to the feedback bus (drained by post-tool-use.ps1) ----------------
$pending = Join-Path $pendingDir "feedback-$cid.txt"
try {
    New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    $prefix = ''
    if ((Test-Path $pending) -and ((Get-Item $pending).Length -gt 0)) { $prefix = "`n`n---`n`n" }
    Add-Content -Path $pending -Value ($prefix + $msg) -NoNewline
} catch { }

# --- arm the latch; record the query hash for next-turn change detection -----
New-Item -ItemType File -Path $latch -Force -ErrorAction SilentlyContinue | Out-Null
if ($currentHash) {
    try { Set-Content -Path $hashFile -Value $currentHash -NoNewline -ErrorAction SilentlyContinue } catch { }
}

exit 0
