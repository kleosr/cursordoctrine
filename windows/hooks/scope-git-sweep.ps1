# scope-git-sweep.ps1 - postToolUse: catch Shell-written files into .scope.json files[].
#
# scope-refresh (afterFileEdit) records files edited via the file-edit tool.
# But edits made through the Shell tool (heredocs, Set-Content, Out-File,
# git apply, build outputs) never fire afterFileEdit, so files[] under-counts
# and milestone-verify stays silent (its gate is files.Count -eq 0). This hook
# closes that gap: on every postToolUse after a Shell/Bash call, run
# `git diff --name-only HEAD` + untracked, and union any new paths into files[].
#
# Reuses scope-refresh's append+prune block verbatim (same <TODO/blank/.scope.json
# filtering, same ordered-dict write-back) so the two hooks stay consistent.
# File-edit-tool tools are skipped (afterFileEdit already recorded them).
#
# Silent exits: kill switch; non-shell tool; no .scope.json; no git; no diff.
# Never emits additional_context — only maintains files[]. The scope-drain /
# scope-refresh reminder chain handles surfacing.
# Disable: HOOKS_ENFORCE=0 or SCOPE_REFRESH_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SCOPE_REFRESH_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

# Only run after Shell-like tools. File-edit tools already fired afterFileEdit.
$toolName = ''
foreach ($k in 'tool_name', 'name', 'toolName', 'tool') {
    if ($obj.PSObject.Properties[$k] -and $obj.$k) { $toolName = [string]$obj.$k; break }
}
$editTools = @('Edit', 'Replace', 'Write', 'MultiEdit', 'editFile', 'file:edit', 'ApplyPatch', 'insert', 'str_replace', 'write', 'edit')
foreach ($e in $editTools) {
    if ($toolName -ieq $e) { exit 0 }
}
$shellTools = @('Shell', 'Bash', 'Execute', 'shell', 'bash', 'RunCommand', 'run', 'terminal', 'cmd', 'powershell')
$isShell = $false
foreach ($s in $shellTools) {
    if ($toolName -ieq $s) { $isShell = $true; break }
}
# Empty tool_name: Cursor payloads sometimes omit it. Treat as shell-candidate
# so we don't miss edits — the git diff is cheap and a no-op when there's no
# change. If it's present and not in either list, also fall through to the
# git check (safe — only unions real diff paths).
if (-not $isShell -and $toolName) {
    # Unknown tool — still run; git diff is the source of truth, not the name.
}

$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path -LiteralPath $scopePath)) { exit 0 }

# Need a git repo for the diff to mean anything.
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

# Union of tracked-changed + untracked paths relative to $root.
$diffPaths = @(& git -C $root diff --name-only HEAD 2>$null) +
             @(& git -C $root ls-files --others --exclude-standard 2>$null)
if (-not $diffPaths -or $diffPaths.Count -eq 0) { exit 0 }

# Reuse scope-refresh's append+prune logic.
$rootFwd = $root.Replace('\', '/').TrimEnd('/')
$existing = @()
if ($sj.PSObject.Properties['files'] -and $sj.files) { $existing = @($sj.files) }
$kept = New-Object System.Collections.Generic.List[string]
foreach ($e in $existing) {
    $s = [string]$e
    if (-not $s -or $s -match '^\s*<TODO' -or [string]::IsNullOrWhiteSpace($s) -or ($s.Trim() -ieq '.scope.json')) { continue }
    $kept.Add($s) | Out-Null
}
$appended = $false
foreach ($p in $diffPaths) {
    $rel = ([string]$p).Replace('\', '/').TrimStart('/')
    # Drop the contract file and any path outside the repo root.
    if (-not $rel -or $rel -ieq '.scope.json') { continue }
    if ($rel -match '^(\.\./|/[A-Za-z]:)') { continue }
    $already = $false
    foreach ($f in $kept) {
        if (([string]$f).Replace('\', '/').TrimStart('/') -ieq $rel) { $already = $true; break }
    }
    if (-not $already) {
        $kept.Add($rel) | Out-Null
        $appended = $true
    }
}

if (-not $appended) { exit 0 }

try {
    $ordered = [ordered]@{}
    foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
    $ordered['files'] = @($kept.ToArray())
    $json = $ordered | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
