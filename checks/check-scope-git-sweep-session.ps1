$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1Hook = (Resolve-Path (Join-Path $here '..\windows\hooks\scope-git-sweep.ps1')).Path
$shHook  = (Resolve-Path (Join-Path $here '..\linux\hooks\scope-git-sweep.sh')).Path
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found at $pwsh" }
if (-not (Test-Path $bash)) { throw "bash.exe not found at $bash" }
$utf8 = [System.Text.UTF8Encoding]::new($false)
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { $git = 'git' }

function Invoke-Sweep([string]$plat, [string]$payload) {
    if ($plat -eq 'PS') {
        $payload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ps1Hook 2>&1 | Out-Null
    } else {
        $payload | & $bash $shHook 2>&1 | Out-Null
    }
}

function Read-Files([string]$dir) {
    $p = Join-Path $dir '.scope.json'
    if (-not (Test-Path $p)) { return @() }
    try {
        $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        return @($o.files)
    } catch { return @() }
}

$tmp = Join-Path $env:TEMP ("cdt-sgs-" + [Guid]::NewGuid().ToString('N'))
$pending = Join-Path $env:USERPROFILE '.cursor\.hooks-pending'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
New-Item -ItemType Directory -Path $pending -Force | Out-Null
$failures = @()

try {
    & $git -C $tmp init -q 2>$null | Out-Null
    & $git -C $tmp config core.autocrlf false 2>$null | Out-Null
    & $git -C $tmp config core.safecrlf false 2>$null | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp 'README.md') -Value "init`n" -Encoding utf8
    & $git -C $tmp add README.md 2>$null | Out-Null
    & $git -C $tmp -c user.email='a@b.c' -c user.name='v' commit -q -m init 2>$null | Out-Null

    $dirty = Join-Path $tmp 'pre-existing-dirty.ts'
    Set-Content -LiteralPath $dirty -Value 'old dirty' -Encoding utf8
    $untracked = Join-Path $tmp 'pre-existing-untracked.ts'
    Set-Content -LiteralPath $untracked -Value 'old untracked' -Encoding utf8
    Start-Sleep -Seconds 2

    $scopeJson = '{"prompt":"p","intent":"t","decomposition":[],"verifications":[],"files":[],"acceptance":"ok"}'
    [System.IO.File]::WriteAllText((Join-Path $tmp '.scope.json'), $scopeJson, $utf8)

    foreach ($plat in 'PS','SH') {
        $cid = "sgs$plat"
        $stamp = Join-Path $pending "session-start-$cid.txt"
        [System.IO.File]::WriteAllText($stamp, [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $utf8)
        $payload = (@{ conversation_id = $cid; cwd = $tmp; tool_name = 'Shell' } | ConvertTo-Json -Compress)
        Invoke-Sweep $plat $payload
        $files = Read-Files $tmp
        $bad = $files | Where-Object {
            $n = ([string]$_).Replace('\', '/').TrimStart('/').ToLowerInvariant()
            $n -eq 'pre-existing-dirty.ts' -or $n -eq 'pre-existing-untracked.ts'
        }
        $ok = ($bad.Count -eq 0)
        Write-Host ("{0} [B4 pre-session dirty isolation] {1} files={2} expect=no pre-session paths" -f $(if($ok){'PASS'}else{'FAIL'}), $plat, (($files | ForEach-Object { $_ }) -join ','))
        if (-not $ok) { $failures += "$plat B4: pre-session dirty paths in files[]: $($files -join ', ')" }
        Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
    }

    if ($failures.Count -gt 0) {
        Write-Host ""; Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "ALL PASS: scope-git-sweep ignores pre-session dirty/untracked when only Shell runs."
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
