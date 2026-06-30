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

function Invoke-HookCapture([string]$payload) {
    $out = $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook 2>$null
    if ($LASTEXITCODE -ne 0) { throw "final-review.ps1 exited $LASTEXITCODE" }
    return ($out -join "`n")
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
    $payload1 = @{ status='completed'; conversation_id=$cid; cwd=$tmp; transcript_path='' } | ConvertTo-Json -Compress
    $out1 = Invoke-HookCapture $payload1
    if ($out1 -notmatch 'followup_message') { throw "run 1 did not emit a followup_message (got: $out1)" }
    $sig1 = (Get-Content $flag -Raw -ErrorAction SilentlyContinue)
    if (-not $sig1) { throw "no signature flag written on run 1 (brake not armed)" }

    & git -C $tmp add src.rs
    & git -C $tmp commit -q -m src
    $srcDirty = & git -C $tmp diff HEAD --name-only -- src.rs 2>$null
    if ($srcDirty) { throw "src.rs still dirty after commit: $srcDirty" }

    $scopeV2 = @{ prompt='p'; intent='test'; decomposition=@(@{ step=1; subtask='rewrote contract'; expected_files=@('src.rs') }); verifications=@(@{ step=1; verdict='ACCEPT'; diagnosis='self-check proof' }); files=@('src.rs'); acceptance='x' } | ConvertTo-Json -Depth 8 -Compress
    Write-Scope $scopeV2

    $tx = Join-Path $tmp 'transcript.jsonl'
    $txLine = @{ message = @{ role='user'; content=@(@{ type='text'; text='<user_query>FINAL REVIEW (end of implementation). Emit a structured bullet report.</user_query>' }) } } | ConvertTo-Json -Compress -Depth 6
    [System.IO.File]::WriteAllText($tx, $txLine, [System.Text.UTF8Encoding]::new($false))

    $payload2 = @{ status='completed'; conversation_id=$cid; cwd=$tmp; transcript_path=$tx } | ConvertTo-Json -Compress
    $out2 = Invoke-HookCapture $payload2
    if ($out2 -notmatch 'followup_message') { throw "run 2 did not re-fire a followup_message on a .scope.json-only rewrite with a clean tree (got: $out2)" }
    $sig2 = (Get-Content $flag -Raw -ErrorAction SilentlyContinue)
    if (-not $sig2) { throw "no signature flag written on run 2" }

    $sig1 = $sig1.Trim()
    $sig2 = $sig2.Trim()
    if ($sig1 -ceq $sig2) {
        throw "FAIL: signature unchanged after .scope.json rewrite (s1=$sig1 s2=$sig2) -- recheck fix not working"
    }
    Write-Host ("PASS: .scope.json-only rewrite on a clean tree re-fired the review and changed the signature (" + $sig1.Substring(0,8) + " -> " + $sig2.Substring(0,8) + ")")
    exit 0
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
}
