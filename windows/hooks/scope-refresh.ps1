# scope-refresh.ps1 - afterFileEdit: record the edit into .scope.json files[], then stash for re-injection.
#
# Two jobs on every edit, both deterministic:
#   1. RECORD: append the edited file to .scope.json's files[] (dedup, preserve
#      order, never touch .scope.json itself). The agent is unreliable at
#      maintaining files[] by hand; this hook keeps it an accurate session
#      footprint without relying on the model. Other fields (intent, acceptance)
#      are preserved verbatim.
#   2. STASH: write a one-line reminder (intent / files / acceptance) to the
#      per-cid pending file. scope-drain.ps1 (postToolUse, fires next) delivers
#      it as additional_context. Per-edit re-injection against Salience
#      Dilution: keeps the contract visible as a turn fills with code.
#
# Cursor does not consume afterFileEdit output directly, which is why the
# stash-and-drain pair exists. Writing .scope.json via [IO.File]::WriteAllText
# is NOT a tool invocation, so it does not re-trigger afterFileEdit.
#
# One state file (scope-<cid>.txt), no hashes, no latches. Silent when no
# .scope.json exists (trivial edits, fresh repos). Disable: HOOKS_ENFORCE=0
# or SCOPE_REFRESH_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SCOPE_REFRESH_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$cid = Get-SafeConversationId $obj
$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
if (-not (Test-Path -LiteralPath $scopePath)) { exit 0 }

try {
    $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $sj) { exit 0 }

# --- 1. RECORD: append the edited file to files[] if not already present --------
$editedFile = ''
foreach ($k in 'file_path', 'path', 'filename', 'absolute_path', 'abs_path') {
    if ($obj.PSObject.Properties[$k] -and $obj.$k) { $editedFile = [string]$obj.$k; break }
}
if ($editedFile) {
    $rel = ConvertTo-FwdPath $editedFile
    if ($rel.StartsWith($root + '/', [System.StringComparison] 'OrdinalIgnoreCase')) {
        $rel = $rel.Substring($root.Length + 1)
    }
    $rel = $rel.TrimStart('/')
    # Never record the contract file itself, and skip empty paths.
    if ($rel -and $rel -ine '.scope.json') {
        $existing = @()
        if ($sj.PSObject.Properties['files'] -and $sj.files) { $existing = @($sj.files) }
        # Drop placeholder / blank entries, normalize for comparison.
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($e in $existing) {
            $s = [string]$e
            if (-not $s -or $s -match '^\s*<TODO' -or [string]::IsNullOrWhiteSpace($s)) { continue }
            $kept.Add($s) | Out-Null
        }
        $already = $false
        foreach ($f in $kept) {
            if (([string]$f).Replace('\', '/').TrimStart('/') -ieq $rel) { $already = $true; break }
        }
        if (-not $already) {
            $kept.Add($rel) | Out-Null
            try {
                # Preserve field order; only replace files[].
                $ordered = [ordered]@{}
                foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
                $ordered['files'] = @($kept.ToArray())
                $json = $ordered | ConvertTo-Json -Depth 8
                [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
                # Refresh $sj so the stash reflects the updated files[].
                $sj = $json | ConvertFrom-Json
            } catch { }
        }
    }
}

# --- 2. STASH: reminder for scope-drain to deliver as additional_context -------
$intent     = if ($sj.PSObject.Properties['intent']     -and $sj.intent)     { [string]$sj.intent } else { '' }
$filesList  = if ($sj.PSObject.Properties['files']      -and $sj.files)      { (@($sj.files) -join ', ') } else { '(none yet)' }
$acceptance = if ($sj.PSObject.Properties['acceptance'] -and $sj.acceptance) { [string]$sj.acceptance } else { '' }

$msg = "SCOPE REMINDER (re-injected after your edit):`n  intent: $intent`n  files: $filesList"
if ($acceptance) { $msg += "`n  acceptance: $acceptance" }
$msg += "`n`nConfirm this edit advances intent. The file you just edited was recorded into files[]."

$pending = Join-Path $HOME ".cursor\.hooks-pending\scope-$cid.txt"
try {
    New-Item -ItemType Directory -Force (Split-Path $pending) | Out-Null
    [System.IO.File]::WriteAllText($pending, $msg, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
