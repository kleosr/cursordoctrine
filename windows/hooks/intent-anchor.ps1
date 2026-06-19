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
#   2. AUTO-CREATE .scope.json (only when the request is READABLE): if no valid
#      contract exists and we can read <user_query>, WRITE one now with intent
#      locked from the query. We NEVER persist a hollow `intent: <TODO>` file:
#      that 0.5.3 "unconditional creation" caused "el .scope.json se escribe
#      solo sin nada" - when Cursor doesn't surface transcript_path on
#      postToolUse the hook can't read the request, so it wrote a placeholder
#      with an empty _intent_hash. The file then looks owned (pre-compile.md
#      tells the agent to leave it alone) and never gets the real intent. When
#      the request is unreadable we write nothing and emit the pre-compile
#      demand so the AGENT authors a real contract from the chat it already has.
#   3. REGENERATE on prompt CHANGE or HOLLOW contract: when the current
#      <user_query> hash differs from the contract's _intent_hash, OR the
#      on-disk contract has no real intent (empty / <TODO> placeholder),
#      overwrite it with the new intent + empty files + TODO acceptance.
#      Requires $hasQuery (you can only lock intent if you can read the
#      request). Never writes to $HOME (bails if no real root resolves -> no
#      ghost files).
#   4. RE-INJECT on same-prompt turns: when the query is unchanged (contract
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

# Stale-latch defense: if a previous session died mid-turn without hitting
# stop (Cursor crash, force-quit), the latch can persist and silence this hook
# for the whole next session -> scope never gets created. If the latch is older
# than 2 hours, treat it as orphaned and clear it. Normal clears happen at
# every stop (final-review.ps1); this is the backstop for abnormal terminations.
if (Test-Path $latch) {
    $age = (Get-Date) - (Get-Item $latch).LastWriteTime
    if ($age.TotalHours -ge 2) { Remove-Item $latch -Force -ErrorAction SilentlyContinue }
}

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
$scopeStale = $false    # true when the on-disk contract belongs to a DIFFERENT prompt -> regenerate (resets files[])
$needsHeal = $false     # true when a model-written contract matches THIS prompt but lacks _intent_hash -> backfill in place
$scopeHasHash = $false
$scopeHollow = $false   # true when the on-disk contract has no real intent (empty or a <TODO> placeholder) -> unusable
$scopePath = Join-Path $root '.scope.json'
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sj.intent)     { $scopeIntent = [string]$sj.intent }
        if ($sj.acceptance) { $scopeAcceptance = [string]$sj.acceptance }
        if ($sj.files)      { $scopeFiles = (@($sj.files) -join ', ') }
        if ([string]::IsNullOrWhiteSpace($scopeFiles)) { $scopeFiles = '(none yet - auto-tracked as you edit)' }
        $scopeExists = $true
        $scopeHasHash = ($sj.PSObject.Properties['_intent_hash'] -and -not [string]::IsNullOrWhiteSpace([string]$sj._intent_hash))
        # Hollow = no real intent on disk: empty, the hook's <TODO> placeholder, OR
        # hook-generated review boilerplate that a stale extractor locked in as the
        # intent (the contamination loop - "FINAL REVIEW (end of implementation)...").
        # A hollow contract is worse than none (it looks owned, so neither hook nor agent
        # fills it; scope-gate appends files to it and final-review audits against garbage).
        # Treat it as unusable: regenerate when we can read the request, else hand the agent
        # the pre-compile demand to write a real one.
        $scopeHollow = ([string]::IsNullOrWhiteSpace($scopeIntent) -or $scopeIntent -match '^\s*<TODO' -or (Test-IsHookGeneratedQuery $scopeIntent))
        # Staleness, hash-agnostic so it survives MODEL-written contracts:
        #   - hook-written (has _intent_hash): stale when that hash != current query hash.
        #   - model-written (no _intent_hash - the legacy pre-compile.md schema): we cannot
        #     hash-compare, so fall back to $promptChanged (current query hash != the per-
        #     conversation last-query hash). Prompt changed (or a new session) => stale ->
        #     regenerate and RESET files[]; this is the "arrastre entre features" fix (a model-
        #     written scope could never go stale, so it never refreshed and scope-gate kept
        #     appending files across unrelated features). Same prompt this session => the model
        #     wrote it for THIS request; heal in place (backfill the bookkeeping, keep its
        #     files[]/acceptance) so the NEXT prompt is detected by hash like any hook contract.
        if ($hasQuery) {
            if ($scopeHollow) {
                # Hollow + we can read the request -> overwrite with the real intent now.
                $scopeStale = $true
            } elseif ($scopeHasHash) {
                $scopeStale = ([string]$sj._intent_hash -ne $currentHash)
            } elseif ($promptChanged) {
                $scopeStale = $true
            } else {
                $needsHeal = $true
            }
        }
    } catch { $scopeExists = $false }   # malformed JSON -> treat as missing
}

# --- auto-create / regenerate / heal .scope.json ----------------------------
# CREATION and REGENERATION both REQUIRE the query. We only ever write a
# contract whose intent we actually know - never a hollow <TODO> scaffold.
# Persisting a placeholder file (the 0.5.3 "unconditional creation") was the
# bug behind "el .scope.json se escribe solo sin nada": when Cursor doesn't
# surface transcript_path on postToolUse, the hook can't read the request, so
# it wrote intent=<TODO> with an empty _intent_hash. That file looks owned, so
# pre-compile.md tells the agent to leave it alone, and it never gets the real
# intent. When the request is unreadable we now write NOTHING and instead hand
# the agent the pre-compile demand to author a real contract from the chat it
# is already responding to. A fresh write resets files[] -> ".scope fresco por
# prompt, sin arrastre entre features." (Hollow on-disk contracts are folded
# into $scopeStale above, so a readable request also overwrites them here.)
$regenerated = $false
$shouldCreate = (-not $scopeExists) -and $hasQuery
$shouldRegen  = $hasQuery -and $scopeExists -and $scopeStale
if ($shouldCreate -or $shouldRegen) {
    try {
        $intentVal  = $currentQuery
        $traceQuery = $currentQuery
        $scaffold = [ordered]@{
            intent        = $intentVal
            files         = @()
            acceptance    = '<TODO: the one deterministic check that decides done>'
            allow_growth  = $false
            trace         = [ordered]@{ query = $traceQuery; ts = (Get-Date).ToString('o') }
            _intent_hash  = $currentHash
            _generated_by = 'intent-anchor hook'
        }
        $json = $scaffold | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
        $scopeIntent     = $intentVal
        $scopeAcceptance = '<TODO: the one deterministic check that decides done>'
        $scopeFiles      = '(auto-tracked - the scope hook records every file you edit)'
        $scopeExists     = $true
        $scopeStale      = $false
        $regenerated     = $true
    } catch { }   # write failed (perms / locked) -> fall through to demand msg
}

# HEAL a model-written contract that matches the current prompt but lacks the
# hook's bookkeeping: backfill _intent_hash + trace + _generated_by IN PLACE,
# preserving the model's files[] and acceptance. Without this, a contract written
# per pre-compile.md (no _intent_hash) can never go stale, so the next prompt
# never regenerates - the carryover bug. Healing installs the hash so the next
# prompt change is detected by hash like any hook-written contract.
if ($needsHeal -and -not $regenerated) {
    try {
        $ordered = [ordered]@{}
        foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
        if (-not $ordered.Contains('trace')) {
            $ordered['trace'] = [ordered]@{ query = $currentQuery; ts = (Get-Date).ToString('o') }
        }
        $ordered['_intent_hash'] = $currentHash
        if (-not $ordered.Contains('_generated_by')) { $ordered['_generated_by'] = 'intent-anchor hook (healed)' }
        $json = $ordered | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
    } catch { }
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
is locked from what you just asked. files[] is AUTO-TRACKED - the scope hook
records every file you edit, so do not maintain it by hand. Set acceptance to
the one deterministic check that decides done, THEN proceed. This contract will
be re-injected every turn until your request changes again.
"@
} elseif (-not $scopeExists -or $scopeHollow) {
    $state = if ($scopeHollow) { "the .scope.json in $root is only a <TODO> placeholder (the hook could not read your request to fill it)" } else { "no .scope.json found in $root, and the current request was unavailable to scaffold from" }
    $msg = @"
INTENT ANCHOR (pre-compile) - $state.

Current request:
  $queryLine

YOU write the real contract to $scopePath now, from THIS conversation, BEFORE
editing source. Do not leave the <TODO> placeholder:
  intent:     one operational sentence - the ACTUAL request (not "<TODO>")
  acceptance: the one deterministic check that decides done
  files:      [] (leave empty - the scope hook records every file you edit)

This is the one case where you own the file: once intent is real, the hook
takes over (re-injection + per-prompt regeneration).
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
