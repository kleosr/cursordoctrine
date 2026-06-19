# scope-gate-audit.ps1 - afterFileEdit "scope auto-record" (Cursor).
#
# Compuerta 1, mechanical edition: keep .scope.json's files[] in sync with what
# the agent ACTUALLY edits, with ZERO reliance on the model remembering to fill
# it. intent-anchor.ps1 writes the scaffold (intent locked from the prompt,
# files: [], acceptance: TODO); THIS hook appends every edited file to files[]
# as the edit happens. Net effect: the contract's files[] is always an accurate
# ledger of the session footprint, which final-review audits against intent
# (the "you touched 8 files for a 1-line request - justify" axis).
#
# This REPLACES the old declared-scope VIOLATION advisory. When every edit is
# auto-recorded, an edit can never be "out of declared scope" - there is nothing
# to violate. The gate became a recorder. acceptance stays the model's to fill:
# a deterministic success check cannot be derived mechanically.
#
# Opt-in: silent if .scope.json does not exist in the repo root (no scaffold yet
# = nothing to maintain). Rewrites ONLY files[]; every other field (intent,
# acceptance, allow_growth, _intent_hash, _generated_by, ...) is preserved.
# Never blocks, never needs Python, ALWAYS exits 0.
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
$rel = $rel.TrimStart('/')
if (Test-IsCursorConfigPath $fp) { exit 0 }
if (Test-IsCursorConfigPath $rel) { exit 0 }
# Never record the contract file into itself.
if ($rel -ieq '.scope.json') { exit 0 }

# --- opt-in gate: no .scope.json = nothing to maintain ---------------------
$scopeFile = "$root/.scope.json"
if (-not (Test-Path -LiteralPath $scopeFile)) { exit 0 }

# --- load the contract; bail quietly on malformed JSON ---------------------
$sj = $null
try { $sj = Get-Content -LiteralPath $scopeFile -Raw | ConvertFrom-Json } catch { exit 0 }
if (-not $sj) { exit 0 }

# --- compute the new files[] -----------------------------------------------
# Start from existing files, drop the scaffold placeholder and blanks, then add
# this edit if it is not already recorded (case-insensitive, slash-normalized).
$existing = @()
if ($sj.PSObject.Properties['files'] -and $sj.files) { $existing = @($sj.files) }

$kept = @()
foreach ($e in $existing) {
    if (-not $e) { continue }
    $s = [string]$e
    if ($s -match '^\s*<TODO') { continue }       # drop the scaffold placeholder
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    $kept += $s
}

$already = $false
foreach ($f in $kept) {
    if (([string]$f).Replace('\', '/').TrimStart('/') -ieq $rel) { $already = $true; break }
}
if (-not $already) { $kept += $rel }

# Only rewrite when files[] actually changed (avoid churning the file on every
# repeat edit of the same path).
$before = ($existing | ForEach-Object { [string]$_ }) -join '|'
$after  = ($kept     | ForEach-Object { [string]$_ }) -join '|'
if ($before -eq $after) { exit 0 }

# --- write back, preserving every other field and its order ----------------
try {
    $ordered = [ordered]@{}
    foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
    $ordered['files'] = @($kept)                  # force array form under pwsh 7
    $json = $ordered | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopeFile, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
