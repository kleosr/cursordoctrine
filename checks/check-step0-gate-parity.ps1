$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1Hook = (Resolve-Path (Join-Path $here '..\windows\hooks\step0-gate.ps1')).Path
$shHook  = (Resolve-Path (Join-Path $here '..\linux\hooks\step0-gate.sh')).Path
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $pwsh)) { throw "pwsh.exe not found at $pwsh" }
if (-not (Test-Path $bash)) { throw "bash.exe not found at $bash" }
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-PsGate([string]$payload, [string]$cwd) {
    $out = $payload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $ps1Hook 2>&1 | Out-String
    if ($out -match '"permission"\s*:\s*"deny"') { return 'DENY' }
    if ($out -match '"permission"\s*:\s*"allow"') { return 'ALLOW' }
    throw "PS step0-gate produced no verdict.`n$out"
}

function Invoke-ShGate([string]$payload, [string]$cwd) {
    $out = $payload | & $bash $shHook 2>&1 | Out-String
    if ($out -match '"permission"\s*:\s*"deny"') { return 'DENY' }
    if ($out -match '"permission"\s*:\s*"allow"') { return 'ALLOW' }
    throw "SH step0-gate produced no verdict.`n$out"
}

function Write-Scope([string]$dir, [string]$json) {
    [System.IO.File]::WriteAllText((Join-Path $dir '.scope.json'), $json, $utf8)
}

function Make-Payload([string]$tool, [string]$toolInput, [string]$cwd) {
    $obj = @{ tool_name = $tool; tool_input = $toolInput; cwd = $cwd }
    return ($obj | ConvertTo-Json -Compress)
}

$tmp = Join-Path $env:TEMP ("cdt-step0-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$failures = @()

try {
    # Case 1: malformed tool_input + empty intent -> DENY (was the Windows bypass)
    Write-Scope $tmp '{"prompt":"p","intent":"","files":[],"decomposition":[]}'
    $p = Make-Payload 'Edit' 'not-json' $tmp
    $ps = Invoke-PsGate $p $tmp; $sh = Invoke-ShGate $p $tmp
    $ok = ($ps -eq 'DENY') -and ($sh -eq 'DENY')
    Write-Host ("{0} [malformed tool_input + empty intent] PS={1} SH={2} expect=DENY" -f $(if($ok){'PASS'}else{'FAIL'}), $ps, $sh)
    if ($ps -ne 'DENY') { $failures += "PS bug6: malformed tool_input + empty intent got $ps (want DENY)" }
    if ($sh -ne 'DENY') { $failures += "SH bug6: malformed tool_input + empty intent got $sh (want DENY)" }

    # Case 2: re-edit SAME file already in files[], no decomposition -> ALLOW
    Write-Scope $tmp '{"prompt":"p","intent":"do task","files":["src.rs"],"decomposition":[]}'
    $p = Make-Payload 'Edit' '{"path":"src.rs"}' $tmp
    $ps = Invoke-PsGate $p $tmp; $sh = Invoke-ShGate $p $tmp
    $ok = ($ps -eq 'ALLOW') -and ($sh -eq 'ALLOW')
    Write-Host ("{0} [re-edit same file, no decomposition] PS={1} SH={2} expect=ALLOW" -f $(if($ok){'PASS'}else{'FAIL'}), $ps, $sh)
    if ($ps -ne 'ALLOW') { $failures += "PS bug9: re-edit same file got $ps (want ALLOW)" }
    if ($sh -ne 'ALLOW') { $failures += "SH bug9: re-edit same file got $sh (want ALLOW)" }

    # Case 3: placeholder decomposition [""] + 2nd DISTINCT file -> DENY
    Write-Scope $tmp '{"prompt":"p","intent":"do task","files":["src.rs"],"decomposition":[""]}'
    $p = Make-Payload 'Edit' '{"path":"other.rs"}' $tmp
    $ps = Invoke-PsGate $p $tmp; $sh = Invoke-ShGate $p $tmp
    $ok = ($ps -eq 'DENY') -and ($sh -eq 'DENY')
    Write-Host ("{0} [placeholder decomp + 2nd distinct file] PS={1} SH={2} expect=DENY" -f $(if($ok){'PASS'}else{'FAIL'}), $ps, $sh)
    if ($ps -ne 'DENY') { $failures += "PS bug21: placeholder decomp + 2nd file got $ps (want DENY)" }
    if ($sh -ne 'DENY') { $failures += "SH bug21: placeholder decomp + 2nd file got $sh (want DENY)" }

    # Case 4: real decomposition + 2nd DISTINCT file -> ALLOW
    $decomp = '{"step":1,"subtask":"real plan","expected_files":["other.rs"]}'
    Write-Scope $tmp ("{`"prompt`":`"p`",`"intent`":`"do task`",`"files`":[`"src.rs`"],`"decomposition`":[$decomp]}")
    $p = Make-Payload 'Edit' '{"path":"other.rs"}' $tmp
    $ps = Invoke-PsGate $p $tmp; $sh = Invoke-ShGate $p $tmp
    $ok = ($ps -eq 'ALLOW') -and ($sh -eq 'ALLOW')
    Write-Host ("{0} [real decomp + 2nd distinct file] PS={1} SH={2} expect=ALLOW" -f $(if($ok){'PASS'}else{'FAIL'}), $ps, $sh)
    if ($ps -ne 'ALLOW') { $failures += "PS control: real decomp + 2nd file got $ps (want ALLOW)" }
    if ($sh -ne 'ALLOW') { $failures += "SH control: real decomp + 2nd file got $sh (want ALLOW)" }

    $rootA = Join-Path $tmp 'ws-a'
    $rootB = Join-Path $tmp 'ws-b'
    New-Item -ItemType Directory -Path $rootA -Force | Out-Null
    New-Item -ItemType Directory -Path $rootB -Force | Out-Null
    Write-Scope $rootA '{"prompt":"p","intent":"do task","files":["a.ts"],"decomposition":[{"step":1,"subtask":"b in ws-b","expected_files":["b.ts"]}]}'
    $targetB = Join-Path $rootB 'b.ts'
    $payloadMulti = @{
        tool_name = 'Write'
        tool_input = @{ path = $targetB }
        cwd = $rootA
        workspace_roots = @($rootA, $rootB)
    } | ConvertTo-Json -Compress
    $ps = Invoke-PsGate $payloadMulti $rootA
    $sh = Invoke-ShGate $payloadMulti $rootA
    $ok = ($ps -eq 'ALLOW') -and ($sh -eq 'ALLOW')
    Write-Host ("{0} [multi-root edit in second workspace] PS={1} SH={2} expect=ALLOW" -f $(if($ok){'PASS'}else{'FAIL'}), $ps, $sh)
    if ($ps -ne 'ALLOW') { $failures += "PS B6: multi-root second workspace got $ps (want ALLOW)" }
    if ($sh -ne 'ALLOW') { $failures += "SH B6: multi-root second workspace got $sh (want ALLOW)" }

    if ($failures.Count -gt 0) {
        Write-Host ""; Write-Host "FAILURES:"
        $failures | ForEach-Object { Write-Host " - $_" }
        exit 1
    }
    Write-Host ""
    Write-Host "ALL PASS: step0-gate fail-open/same-file/placeholder fixes verified on both platforms."
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
