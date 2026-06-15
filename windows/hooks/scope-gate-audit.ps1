# scope-gate-audit.ps1 - afterFileEdit "declared scope" advisory (Cursor).
#
# Compuerta 1 of the anti-slop system: the declared-scope gate. When the agent
# writes a .scope.json contract (intent + files[] + acceptance), this hook
# checks every edited file against it. Editing OUTSIDE the declared set is the
# textbook scope-creep / gold-plating signal - the agent is doing work it did
# not declare. Advisory only on Cursor (no preToolUse for file edits), but the
# violation is flagged on the next turn and the model must justify or revert.
#
# Opt-in: if .scope.json does not exist in the repo root, this hook is silent.
# Declared-editing discipline is something the agent opts into by writing the
# contract. No contract = no gate (fallback to declared-editing ladder + the
# footprint check in final-review).
#
# Mechanism: resolve edited file -> repo-relative, run scope_match.py against
# .scope.json's files[], append advisory to feedback-<cid>.txt on violation.
# Identical pattern to semantic-density-audit and anti-slop-audit.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0.
# Disable: HOOKS_ENFORCE=0  or  SCOPE_GATE_ENFORCE=0

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SCOPE_GATE_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

# audit root: project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
$root = ''
$cands = @()
if ($obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
if ($obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
foreach ($c in $cands) { $f = ConvertTo-FwdPath $c; if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break } }
if (-not $root) { $root = (& { if ($env:CURSOR_PROJECT_DIR) { $env:CURSOR_PROJECT_DIR } else { $HOME } }).Replace('\', '/').TrimEnd('/') }

# edited file -> repo-relative forward-slash path
$fp = ''
foreach ($k in 'file_path', 'path', 'filename', 'absolute_path', 'abs_path') {
    if ($obj.PSObject.Properties[$k] -and $obj.$k) { $fp = [string]$obj.$k; break }
}
if (-not $fp) { exit 0 }
$rel = ConvertTo-FwdPath $fp
if ($rel.StartsWith($root + '/', [System.StringComparison] 'OrdinalIgnoreCase')) { $rel = $rel.Substring($root.Length + 1) }
if (Test-IsCursorConfigPath $fp) { exit 0 }
if (Test-IsCursorConfigPath $rel) { exit 0 }

# --- opt-in gate: no .scope.json = no gate ---------------------------------
$scopeFile = "$root/.scope.json"
if (-not (Test-Path -LiteralPath $scopeFile)) { exit 0 }

# --- resolve Python + run scope_match.py -----------------------------------
$py = Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $py) { exit 0 }   # no Python -> fail open

$matcher = Join-Path $HOME '.cursor\skills\anti-slop\scripts\scope_match.py'
if (-not (Test-Path $matcher)) { exit 0 }   # skill not installed -> silent

$mout = & $py.Source $matcher --path $rel --patterns-file $scopeFile 2>$null
if (-not $mout) { exit 0 }

$payload = $null
try { $payload = ($mout -join "`n") | ConvertFrom-Json } catch { }
if (-not $payload) { exit 0 }

# fail-open: if scope_match reported skipped (no valid contract), stay silent
$hasSkipped = $false
try { if ($payload.PSObject.Properties['skipped']) { $hasSkipped = $true } } catch { }
if ($hasSkipped) { exit 0 }

$inScope = $false
try { $inScope = [bool]$payload.in_scope } catch { }
if ($inScope) { exit 0 }

# --- violation: compose advisory -------------------------------------------
$allowGrowth = $false
if ($payload.PSObject.Properties['allow_growth'] -and $payload.allow_growth) { $allowGrowth = $true }
$intent = ''
if ($payload.PSObject.Properties['intent']) { $intent = [string]$payload.intent }

# Read the declared files list for the message (best-effort; skip on failure)
$declaredFiles = ''
try {
    $scopeJson = Get-Content -LiteralPath $scopeFile -Raw | ConvertFrom-Json
    if ($scopeJson.files) { $declaredFiles = ($scopeJson.files -join ', ') }
} catch { }

if ($allowGrowth) {
    # Growth is allowed: informational, not a violation
    $summary = "Scope note - $rel is new vs your declared scope (growth allowed)"
    $body = @"
  You touched a file outside your initial declared set. Since allow_growth is
  true, this is not a violation, but justify it: add $rel to .scope.json or
  explain why the scope grew.
"@
} else {
    # Hard violation: edited outside the declared contract
    $summary = "[SCOPE VIOLATION] $rel is NOT in your declared scope"
    $body = @"
  Your contract (.scope.json):
    intent: $intent
    files: $declaredFiles

  You declared these files and touched one outside the set. Either:
    1. Add $rel to .scope.json with a one-line justification, OR
    2. Revert the change - it is out of scope for the declared intent.

  Declared-editing: declare BEFORE you expand. Don't sneak edits past the gate.
"@
}

$msg = "$summary`n`n$body`n`n(Advisory; disable: SCOPE_GATE_ENFORCE=0)"

# --- append to the shared pending file --------------------------------------
$cid = Get-SafeConversationId $obj
$pending = Join-Path (Get-HooksPendingDir) "feedback-$cid.txt"
try {
    New-Item -ItemType Directory -Path (Split-Path $pending) -Force | Out-Null
    $prefix = ''
    if ((Test-Path $pending) -and ((Get-Item $pending).Length -gt 0)) { $prefix = "`n`n---`n`n" }
    Add-Content -Path $pending -Value ($prefix + $msg) -NoNewline
} catch { }

exit 0
