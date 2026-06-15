# semantic-density-audit.ps1 - afterFileEdit "semantic opacity" advisory (Cursor).
#
# Guards the naming layer the other audit hooks do not see. minimal-edit-audit
# watches diff SIZE; anti-slop-audit watches generated-code PATTERNS; this hook
# watches whether the identifiers the agent JUST introduced actually communicate
# intent. DataManager, process(), utils.ts, CoreEngine - names that exist but
# say nothing.
#
# Mechanism: extract ADDED lines from `git diff HEAD -- <rel>` (with the
# untracked-file fallback anti-slop-audit uses), pipe them to density_scan.py
# (a thin wrapper over the shared low_density module), read back one JSON
# object of findings, append a short advisory to the shared pending-feedback
# file. One denylist, shared with scan_slop.py's semantic_density bucket -
# zero drift between the per-edit advisory and the audit-of-record.
#
# FAIL findings (DataManager / Utils / placeholder names) always fire. WARN
# findings (defensible DDD with a domain noun - PostgresUserRepository) only
# fire when at least one FAIL is also present, so the hook stays quiet on
# legitimate code and loud on the real slop.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0 (afterFileEdit
# output isn't consumed and a non-zero exit shows as "hook failed").
# Disable: HOOKS_ENFORCE=0  or  SEMANTIC_DENSITY_ENFORCE=0

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SEMANTIC_DENSITY_ENFORCE -eq '0') { exit 0 }

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

# git repo?
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

# --- collect ADDED lines for this file (working tree vs HEAD) --------------
$added = New-Object System.Collections.Generic.List[string]
foreach ($l in (& git -C $root diff HEAD -- $rel 2>$null)) {
    if ($l.Length -gt 0 -and $l[0] -eq '+' -and -not $l.StartsWith('+++')) {
        $added.Add($l.Substring(1))
    }
}
if ($added.Count -eq 0) {
    # untracked / brand-new file: git diff HEAD shows nothing -> whole file is "added"
    & git -C $root ls-files --error-unmatch -- $rel 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $abs = "$root/$rel"
        if (Test-Path -LiteralPath $abs) {
            foreach ($l in (Get-Content -LiteralPath $abs)) { $added.Add([string]$l) }
        }
    }
}
if ($added.Count -eq 0) { exit 0 }
if ($added.Count -gt 1500) { $added = $added.GetRange(0, 1500) }

# --- resolve Python + run density_scan.py ---------------------------------
# Windows often ships the interpreter as `py` or `python3`, not `python`.
$py = Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $py) { exit 0 }   # no Python -> fail open, scanner unavailable

$scanner = Join-Path $HOME '.cursor\skills\anti-slop\scripts\density_scan.py'
if (-not (Test-Path $scanner)) { exit 0 }   # skill not installed -> silent

# Pipe added lines to the scanner via stdin, read JSON back. PowerShell pipes
# objects (not bytes) to a native process; joining into one string preserves
# the line breaks density_scan expects.
$addedText = ($added -join "`n")
$mout = $addedText | & $py.Source $scanner --rel $rel 2>$null
if (-not $mout) { exit 0 }

$payload = $null
try { $payload = ($mout -join "`n") | ConvertFrom-Json } catch { }
if (-not $payload -or -not $payload.findings) { exit 0 }

# --- decide whether to fire -------------------------------------------------
# FAIL always fires. WARN only fires alongside a FAIL, so defensible DDD
# (PostgresUserRepository) stays quiet when there is nothing else to say.
$fails = @($payload.findings | Where-Object { $_.severity -eq 'fail' })
$warns = @($payload.findings | Where-Object { $_.severity -eq 'warn' })
if ($fails.Count -eq 0 -and $warns.Count -eq 0) { exit 0 }

$flagged = $fails
if ($fails.Count -gt 0) { $flagged = @($fails) + @($warns) }

# --- compose advisory (concatenated, not interpolated: denylist text is safe) ---
$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in $flagged | Select-Object -First 12) {
    $tag = $f.severity.ToUpper()
    $where = if ($f.line -and $f.line -gt 0) { "line $($f.line)" } else { 'file name' }
    $reason = ($f.reasons -join '; ')
    if ($reason.Length -gt 110) { $reason = $reason.Substring(0, 107) + '...' }
    $lines.Add("  [$tag] $($f.kind) '$($f.name)' ($where): $reason")
}

$summary = "Semantic-density audit - $rel"
$summary += " - $($payload.fail_count) FAIL, $($payload.warn_count) WARN"
$advice = @"
  High-density names are predictable from the name alone (InvoiceEmailSender,
  PostgresUserRepository, GenerateMonthlyReport). Low-density names name a
  category, not a thing (Manager, Utils, process, handleThing). Rename so the
  identifier states its concrete responsibility. WARNs with a domain noun are
  defensible DDD and can be left if intentional.
"@

$msg = "$summary`n`n" + ($lines -join "`n") + "`n`n$advice`n`n(Advisory; disable: SEMANTIC_DENSITY_ENFORCE=0)"

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
