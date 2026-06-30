$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = (Resolve-Path (Join-Path $here '..\windows\hooks\final-review.ps1')).Path
$tmp = Join-Path $env:TEMP ("cdt-recheck-" + [Guid]::NewGuid().ToString('N'))
$cid = 'cdt-check-recheck'
$flag = "$HOME\.cursor\.hooks-pending\reviewed-$cid.flag"
Remove-Item $flag -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Write-Scope([string]$json) {
    [System.IO.File]::WriteAllText((Join-Path $tmp '.scope.json'), $json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Hook([string]$payload) {
    $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "final-review.ps1 exited $LASTEXITCODE" }
}

try {
    & git -C $tmp init -q
    & git -C $tmp config user.email "t@t"
    & git -C $tmp config user.name "t"
    $src = Join-Path $tmp 'src.rs'
    Set-Content -LiteralPath $src -Value 'fn main(){}' -Encoding UTF8
    & git -C $tmp add src.rs
    & git -C $tmp commit -q -m base
    Set-Content -LiteralPath $src -Value 'fn main(){ let x = 1; }' -Encoding UTF8

    $scopeV1 = @{ prompt='p'; intent='test'; decomposition=@(); verifications=@(); files=@('src.rs'); acceptance='x' } | ConvertTo-Json -Depth 8 -Compress
    Write-Scope $scopeV1
    $payload = @{ status='completed'; conversation_id=$cid; cwd=$tmp; transcript_path='' } | ConvertTo-Json -Compress
    Invoke-Hook $payload
    $sig1 = (Get-Content $flag -Raw -ErrorAction SilentlyContinue)
    if (-not $sig1) { throw "no signature flag written on run 1" }

    $scopeV2 = @{ prompt='p'; intent='test'; decomposition=@(@{ step=1; subtask='rewrote contract'; expected_files=@('src.rs') }); verifications=@(@{ step=1; verdict='ACCEPT'; diagnosis='' }); files=@('src.rs'); acceptance='x' } | ConvertTo-Json -Depth 8 -Compress
    Write-Scope $scopeV2
    Invoke-Hook $payload
    $sig2 = (Get-Content $flag -Raw -ErrorAction SilentlyContinue)
    if (-not $sig2) { throw "no signature flag written on run 2" }

    $sig1 = $sig1.Trim()
    $sig2 = $sig2.Trim()
    if ($sig1 -ceq $sig2) {
        throw "FAIL: signature unchanged after .scope.json rewrite (s1=$sig1 s2=$sig2) -- recheck fix not working"
    }
    Write-Host ("PASS: .scope.json rewrite changed the verify-revise signature (" + $sig1.Substring(0,8) + " -> " + $sig2.Substring(0,8) + ")")
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
}
