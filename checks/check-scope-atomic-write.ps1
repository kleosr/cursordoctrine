$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$psCommon = (Resolve-Path (Join-Path $here '..\windows\hooks\hook-common.ps1')).Path
$shCommon = (Resolve-Path (Join-Path $here '..\linux\hooks\hook-common.sh')).Path
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) { throw "bash.exe not found at $bash" }
$shCommonFwd = $shCommon -replace '\\','/'

. $psCommon

function Write-ContentFile([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ShAtomic([string]$scopePath, [string]$contentFile) {
    $scopeFwd = $scopePath -replace '\\','/'
    $contentFwd = $contentFile -replace '\\','/'
    $probe = @"
. "$shCommonFwd"
c=`$(cat '$contentFwd')
write_scope_json_atomic "$scopeFwd" "`$c"
"@
    $probe | & $bash 2>$null
}

$tmp = Join-Path $env:TEMP ("cdt-atomic-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$failures = @()
$utf8 = [System.Text.UTF8Encoding]::new($false)

try {
    $original = '{"prompt":"p","intent":"keep me","files":[]}'
    $updated  = '{"prompt":"p","intent":"new","files":["a.rs"]}'
    $emptyFile = Join-Path $tmp 'empty.txt'; Write-ContentFile $emptyFile ''
    $updFile   = Join-Path $tmp 'updated.json'; Write-ContentFile $updFile $updated

    # --- PS1: empty content must NOT truncate the existing file ---
    $psScope = Join-Path $tmp 'ps-scope.json'
    Write-ContentFile $psScope $original
    Write-ScopeJsonAtomic $psScope ''
    $after = [System.IO.File]::ReadAllText($psScope).Trim()
    if ($after -ne $original) { $failures += "PS empty-content: file truncated (got: $after)"; Write-Host "FAIL PS empty-content: got='$after'" }
    else { Write-Host "PASS PS empty-content: file unchanged (no truncation)" }
    if (Test-Path "$psScope.lock") { $failures += "PS: lock sentinel left behind"; Write-Host "FAIL PS: lock residue" }
    if (Test-Path "$psScope.tmp")  { $failures += "PS: tmp file left behind"; Write-Host "FAIL PS: tmp residue" }

    # --- PS1: valid content updates atomically ---
    Write-ScopeJsonAtomic $psScope $updated
    $after = [System.IO.File]::ReadAllText($psScope).Trim()
    if ($after -ne $updated) { $failures += "PS valid-content: file not updated (got: $after)"; Write-Host "FAIL PS valid-content: got='$after'" }
    else { Write-Host "PASS PS valid-content: file updated atomically" }

    # --- SH: empty content must NOT truncate the existing file ---
    $shScope = Join-Path $tmp 'sh-scope.json'
    Write-ContentFile $shScope $original
    Invoke-ShAtomic $shScope $emptyFile
    $after = [System.IO.File]::ReadAllText($shScope).Trim()
    if ($after -ne $original) { $failures += "SH empty-content: file truncated (got: $after)"; Write-Host "FAIL SH empty-content: got='$after'" }
    else { Write-Host "PASS SH empty-content: file unchanged (no truncation)" }
    if (Test-Path "$shScope.lock") { $failures += "SH: lock sentinel left behind"; Write-Host "FAIL SH: lock residue" }

    # --- SH: valid content updates atomically ---
    Invoke-ShAtomic $shScope $updFile
    $after = [System.IO.File]::ReadAllText($shScope).Trim()
    if ($after -ne $updated) { $failures += "SH valid-content: file not updated (got: $after)"; Write-Host "FAIL SH valid-content: got='$after'" }
    else { Write-Host "PASS SH valid-content: file updated atomically" }

    if ($failures.Count -gt 0) {
        Write-Host ""; Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "ALL PASS: .scope.json atomic write + no-truncation verified on both platforms."
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
