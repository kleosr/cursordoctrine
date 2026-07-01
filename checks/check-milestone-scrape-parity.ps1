$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1Hook = (Resolve-Path (Join-Path $here '..\windows\hooks\milestone-verify.ps1')).Path
$shHook  = (Resolve-Path (Join-Path $here '..\linux\hooks\milestone-verify.sh')).Path
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found at $pwsh" }
if (-not (Test-Path $bash)) { throw "bash.exe not found at $bash" }
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Scope([string]$dir, [string]$json) {
    [System.IO.File]::WriteAllText((Join-Path $dir '.scope.json'), $json, $utf8)
}

function Write-Transcript([string]$path, [string]$assistantText) {
    $rec = @{ role = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $assistantText }) } }
    [System.IO.File]::WriteAllText($path, ($rec | ConvertTo-Json -Depth 6 -Compress) + "`n", $utf8)
}

function Read-Verifications([string]$dir) {
    $p = Join-Path $dir '.scope.json'
    if (-not (Test-Path $p)) { return $null }
    try { $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return $null }
    return $o.verifications
}

function Invoke-PsHook([string]$payload) {
    $payload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ps1Hook 2>&1 | Out-Null
}

function Invoke-ShHook([string]$payload) {
    $payload | & $bash $shHook 2>&1 | Out-Null
}

function Make-Payload([string]$cid, [string]$tpFwd, [string]$cwdFwd) {
    return @{ conversation_id = $cid; transcript_path = $tpFwd; cwd = $cwdFwd } | ConvertTo-Json -Compress
}

function Reset-Scope([string]$dir) {
    Write-Scope $dir '{"prompt":"p","intent":"do task","decomposition":[{"step":1,"subtask":"a","expected_files":["a.ts"]},{"step":2,"subtask":"b","expected_files":["b.ts"]}],"verifications":[],"files":["a.ts"],"acceptance":"ok"}'
}

$tmp = Join-Path $env:TEMP ("cdt-mv-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$tpA = Join-Path $tmp 'ta.jsonl'
$tpB = Join-Path $tmp 'tb.jsonl'
$tpC = Join-Path $tmp 'tc.jsonl'
$tmpFwd = $tmp -replace '\\','/'
$tpAFwd = $tpA -replace '\\','/'
$tpBFwd = $tpB -replace '\\','/'
$tpCFwd = $tpC -replace '\\','/'
$failures = @()

try {
    # --- Case A: rightmost verdict wins (model revises within one turn) ---
    Write-Transcript $tpA "I'll ACCEPT step 1`nOn review, REVISE step 1: off-by-one in the loop"
    foreach ($plat in 'PS','SH') {
        Reset-Scope $tmp
        $p = Make-Payload "cA$plat" $tpAFwd $tmpFwd
        if ($plat -eq 'PS') { Invoke-PsHook $p } else { Invoke-ShHook $p }
        $v = Read-Verifications $tmp
        $entry = $null
        if ($v) { $entry = $v | Where-Object { $_.step -eq 1 } | Select-Object -First 1 }
        $got = if ($entry) { $entry.verdict } else { '(none)' }
        $ok = $entry -and $entry.verdict -eq 'REVISE'
        Write-Host ("{0} [A rightmost verdict] {1}={2} expect=REVISE" -f $(if($ok){'PASS'}else{'FAIL'}), $plat, $got)
        if (-not $ok) { $failures += "$plat A: rightmost verdict got $got (want REVISE)" }
    }

    # --- Case B: scraped step not in decomposition[] is rejected ---
    Write-Transcript $tpB "ACCEPT step 99: hallucinated step"
    foreach ($plat in 'PS','SH') {
        Reset-Scope $tmp
        $p = Make-Payload "cB$plat" $tpBFwd $tmpFwd
        if ($plat -eq 'PS') { Invoke-PsHook $p } else { Invoke-ShHook $p }
        $v = Read-Verifications $tmp
        $has99 = $false
        if ($v) { if ($v | Where-Object { $_.step -eq 99 }) { $has99 = $true } }
        $ok = -not $has99
        Write-Host ("{0} [B reject step not in decomposition] {1} has99={2} expect=False" -f $(if($ok){'PASS'}else{'FAIL'}), $plat, $has99)
        if (-not $ok) { $failures += "$plat B: scraped step 99 was recorded (should be rejected)" }
    }

    # --- Case C: verdict inside a fenced code block is not scraped ---
    $caseCtext = @'
Here is an example verdict:
```bash
ACCEPT step 1
```
No real verdict yet.
'@
    Write-Transcript $tpC $caseCtext
    foreach ($plat in 'PS','SH') {
        Reset-Scope $tmp
        $p = Make-Payload "cC$plat" $tpCFwd $tmpFwd
        if ($plat -eq 'PS') { Invoke-PsHook $p } else { Invoke-ShHook $p }
        $v = Read-Verifications $tmp
        $has1 = $false
        if ($v) { if ($v | Where-Object { $_.step -eq 1 -and $_.verdict -ne 'PENDING' }) { $has1 = $true } }
        $ok = -not $has1
        Write-Host ("{0} [C fenced verdict not scraped] {1} scraped={2} expect=False" -f $(if($ok){'PASS'}else{'FAIL'}), $plat, $has1)
        if (-not $ok) { $failures += "$plat C: fenced 'ACCEPT step 1' was scraped (should be stripped)" }
    }

    if ($failures.Count -gt 0) {
        Write-Host ""; Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "ALL PASS: milestone-verify rightmost-match + decomp-validation + fence-strip verified on both platforms."
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
