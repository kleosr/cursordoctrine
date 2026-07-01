$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1Hook = (Resolve-Path (Join-Path $here '..\windows\hooks\scope-refresh.ps1')).Path
$shHook  = (Resolve-Path (Join-Path $here '..\linux\hooks\scope-refresh.sh')).Path
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found at $pwsh" }
if (-not (Test-Path $bash)) { throw "bash.exe not found at $bash" }
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Scope([string]$dir, [string]$json) {
    [System.IO.File]::WriteAllText((Join-Path $dir '.scope.json'), $json, $utf8)
}
function Read-Files([string]$dir) {
    $p = Join-Path $dir '.scope.json'
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).files } catch { return $null }
}
function Make-Payload([string]$cid, [string]$cwdFwd, [string]$filePath) {
    return @{ conversation_id = $cid; cwd = $cwdFwd; file_path = $filePath } | ConvertTo-Json -Compress
}

$tmp = Join-Path $env:TEMP ("cdt-srd-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$tmpFwd = $tmp -replace '\\','/'
$failures = @()

try {
    # Existing files[] has a backslash entry; the new edit uses forward slashes.
    # The hook must normalize and dedup -> exactly ONE entry, not two.
    $seed = '{"prompt":"p","intent":"do task","decomposition":[],"verifications":[],"files":["src\\foo.ts"],"acceptance":"ok"}'

    foreach ($plat in 'PS','SH') {
        Write-Scope $tmp $seed
        $p = Make-Payload "dedup$plat" $tmpFwd (Join-Path $tmpFwd 'src/foo.ts')
        if ($plat -eq 'PS') {
            $p | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ps1Hook 2>&1 | Out-Null
        } else {
            $p | & $bash $shHook 2>&1 | Out-Null
        }
        $files = Read-Files $tmp
        $count = if ($files) { @($files).Count } else { 0 }
        $norm = @($files | ForEach-Object { ("$_" -replace '\\','/') }) | Sort-Object -Unique
        $uniqueCount = $norm.Count
        $ok = ($count -ge 1) -and ($count -le 2) -and ($uniqueCount -eq 1)
        $list = ($files | ForEach-Object { "$_" }) -join ', '
        Write-Host ("{0} [{1}] files[]={2} unique={3} expect=1 unique entry" -f $(if($ok){'PASS'}else{'FAIL'}), $plat, $list, $uniqueCount)
        if (-not $ok) { $failures += "$plat dedup: got [$list] unique=$uniqueCount (want 1 unique entry)" }
    }

    if ($failures.Count -gt 0) {
        Write-Host ""; Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "ALL PASS: scope-refresh backslash/forward-slash dedup verified on both platforms."
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
