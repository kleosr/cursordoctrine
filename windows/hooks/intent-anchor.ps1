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
#   2. RE-COMPILE ON PROMPT CHANGE: hash the current <user_query> (via
#      Get-LastUserQuery, which reads the transcript) and compare to
#      last-query-<cid>.hash. If they differ and a valid .scope.json exists,
#      demand the agent UPDATE it. If no valid .scope.json exists and the query
#      is available, WRITE a deterministic scaffold to disk (intent = query,
#      files/acceptance = TODO placeholders) so re-injection always has real
#      content from the first tool boundary — contract creation is not left to
#      the LLM alone.
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
$root = ''
$cands = @()
if ($obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
if ($obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
foreach ($c in $cands) { $f = ConvertTo-FwdPath $c; if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break } }
if (-not $root) { $root = (& { if ($env:CURSOR_PROJECT_DIR) { $env:CURSOR_PROJECT_DIR } else { $HOME } }).Replace('\', '/').TrimEnd('/') }

# --- read the existing contract (if any) -------------------------------------
$scopeExists = $false
$scopeIntent = ''
$scopeAcceptance = ''
$scopeFiles = ''
$scopePath = Join-Path $root '.scope.json'
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sj.intent)     { $scopeIntent = [string]$sj.intent }
        if ($sj.acceptance) { $scopeAcceptance = [string]$sj.acceptance }
        if ($sj.files)      { $scopeFiles = ($sj.files -join ', ') }
        $scopeExists = $true
    } catch { $scopeExists = $false }   # malformed JSON -> treat as missing
}

# --- deterministic scaffold (0.4.4) -----------------------------------------
# When the query is available and there is no valid contract, the hook writes
# .scope.json itself — intent from <user_query>, obvious TODO placeholders
# for files/acceptance. Fires on prompt change (incl. first turn: empty prev
# hash) or whenever the contract is still missing on a turn boundary.
$scaffoldWritten = $false
$shouldScaffold = $hasQuery -and (-not $scopeExists)
if ($shouldScaffold) {
    try {
        $scaffold = [ordered]@{
            intent       = $currentQuery
            files        = @('<TODO: list files>')
            acceptance   = '<TODO: deterministic success check>'
            allow_growth = $false
        }
        $json = $scaffold | ConvertTo-Json -Depth 4 -Compress
        $dir = Split-Path -Parent $scopePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
        $scopeIntent = $currentQuery
        $scopeAcceptance = '<TODO: deterministic success check>'
        $scopeFiles = '<TODO: list files>'
        $scopeExists = $true
        $scaffoldWritten = $true
    } catch { }
}

# --- compose the anchor message ---------------------------------------------
# Re-injection (req 2) is unconditional whenever a contract exists.
# Recompile-demand (req 1) fires when the prompt moved but a real contract exists.
$queryLine = if ($hasQuery) { $currentQuery } else { '(current request unavailable - no transcript in this event)' }

if ($scaffoldWritten) {
    $msg = @"
INTENT ANCHOR (scaffold written to .scope.json) - contract materialized from your request.

  intent:     $scopeIntent
  files:      $scopeFiles
  acceptance: $scopeAcceptance

The hook wrote this scaffold to $scopePath — intent is locked from your current
request. Replace the TODO placeholders with real files[] and acceptance before
editing source. The contract is on disk and will be re-injected every turn.
"@
} elseif (-not $scopeExists) {
    $msg = @"
INTENT ANCHOR (pre-compile) - no .scope.json found in $root.

Current request:
  $queryLine

You have NOT compiled your Anchor Set. Before editing files, write .scope.json
in the repo root:
  intent:     one operational sentence (what is strictly necessary)
  files:      the exact files you will touch
  acceptance: the one deterministic check that decides done

Compile it now, then proceed. The scope tracks the request - it is how you stay
on the rails when the conversation gets long.
"@
} elseif ($promptChanged) {
    $msg = @"
INTENT ANCHOR (pre-compile) - your request changed; .scope.json may be stale.

Current request:
  $queryLine

Your existing contract (.scope.json):
  intent:     $scopeIntent
  files:      $scopeFiles
  acceptance: $scopeAcceptance

If the current request differs from the intent above, UPDATE .scope.json now
to match what was just asked. When the request moves, the scope moves with it -
do not edit against a contract written for a different request.
"@
} else {
    # Same prompt continuing (or query unavailable) -> re-inject the contract.
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
