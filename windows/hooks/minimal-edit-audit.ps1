# minimal-edit-audit.ps1 - afterFileEdit minimal-editing advisory (Cursor).
#
# Audits the just-edited file for over-editing:
#   * line-count  - git diff --numstat thresholds (any language). Native git,
#                   no bash (Git's MSYS bash mangles Windows paths / lacks PATH
#                   when spawned from pwsh, so we compute this directly).
#   * token metrics - audit-metrics.py (token-Levenshtein + cognitive
#                   complexity), Python files only, via a resolved interpreter.
# On WARN/FAIL it APPENDS a short advisory to the shared pending-feedback file;
# post-tool-use.ps1 delivers it as additional_context on the next tool turn.
#
# Advisory only: never blocks, never writes persistent state. afterFileEdit
# output isn't consumed and a non-zero exit shows as "hook failed", so we
# ALWAYS exit 0. Self-contained.
#
# Thresholds (env-overridable): MINIMAL_EDIT_FAIL_LINES (400), MINIMAL_EDIT_WARN_LINES (100).
# Disable: HOOKS_ENFORCE=0  or  MINIMAL_EDITING_ENFORCE=0

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:MINIMAL_EDITING_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

# audit root = project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
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
if ($rel.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($root.Length + 1) }
if (Test-IsCursorConfigPath $fp) { exit 0 }
if (Test-IsCursorConfigPath $rel) { exit 0 }

# git repo?
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

# --- line-count audit (any language) via native git ----------------------
$failLines = if ($env:MINIMAL_EDIT_FAIL_LINES) { [int]$env:MINIMAL_EDIT_FAIL_LINES } else { 400 }
$warnLines = if ($env:MINIMAL_EDIT_WARN_LINES) { [int]$env:MINIMAL_EDIT_WARN_LINES } else { 100 }
$ins = 0; $del = 0
foreach ($line in (& git -C $root diff HEAD --numstat -- $rel 2>$null)) {
    $parts = $line -split "`t"
    if ($parts.Count -lt 3 -or $parts[0] -eq '-') { continue }   # skip header/binary
    $ins += [int]$parts[0]; $del += [int]$parts[1]
}
$changed = $ins + $del

$grade = 'OK'; $hint = ''
if ($changed -gt $failLines) { $grade = 'FAIL'; $hint = "$changed lines changed (limit $failLines) - likely over-editing; trim or split" }
elseif ($changed -gt $warnLines) { $grade = 'WARN'; $hint = "$changed lines changed - justify each hunk or split the task" }

# --- token metrics (.py only) via a resolved interpreter -----------------
$auditMetrics = Join-Path $HOME '.cursor\skills\minimal-editing\scripts\audit-metrics.py'
if ((Test-Path $auditMetrics) -and ($rel -match '\.py$')) {
    # Windows often ships the interpreter as `py` or `python3`, not `python`.
    # Without this resolution the call errored silently and .py metrics never ran.
    $py = Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $mout = & $py.Source $auditMetrics --root $root --format json --path $rel 2>$null
        $mo = $null; try { $mo = ($mout -join "`n") | ConvertFrom-Json } catch { }
        if ($mo -and $mo.grade) {
            if ($mo.grade -eq 'FAIL') { $grade = 'FAIL' }
            elseif ($mo.grade -eq 'WARN' -and $grade -eq 'OK') { $grade = 'WARN' }
        }
    }
}

if ($grade -eq 'OK') { exit 0 }

# --- compose advisory + append to the shared pending file ----------------
$hintTxt = if ($hint) { " - $hint" } else { '' }
if ($grade -eq 'FAIL') {
    $actions = @"
  - Trim every hunk that isn't required by the task.
  - Prefer narrow, targeted edits over rewriting blocks.
  - If the change is genuinely large, split it into smaller logical commits.
"@
} else {
    $actions = '  Advisory only - trim unrelated hunks if any; otherwise proceed.'
}

$msg = @"
Minimal-edit audit $grade - $rel

IMPORTANT: Try to preserve the original code and the logic of the original code as much as possible.

grade: $grade$hintTxt

$actions

(Disable for this session: HOOKS_ENFORCE=0)
"@

$cid = Get-SafeConversationId $obj
$pending = Join-Path (Get-HooksPendingDir) "feedback-$cid.txt"
try {
    New-Item -ItemType Directory -Path (Split-Path $pending) -Force | Out-Null
    $prefix = ''
    if ((Test-Path $pending) -and ((Get-Item $pending).Length -gt 0)) { $prefix = "`n`n---`n`n" }
    Add-Content -Path $pending -Value ($prefix + $msg) -NoNewline
} catch { }

exit 0
