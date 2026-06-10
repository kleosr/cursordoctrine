# hook-common.ps1 - shared helpers for Cursor agent hooks.
# Dot-source from sibling scripts: . "$PSScriptRoot\hook-common.ps1"

function Read-HookStdin {
    $ms = [System.IO.MemoryStream]::new()
    [Console]::OpenStandardInput().CopyTo($ms)
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF).Trim()
}

function Read-HookStdinJson {
    $raw = Read-HookStdin
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Write-HookJson($payload) {
    $json = $payload | ConvertTo-Json -Compress
    $sb = [System.Text.StringBuilder]::new($json.Length + 64)
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 32 -or $code -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
        else { [void]$sb.Append($ch) }
    }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

function Get-SafeConversationId($obj) {
    $cid = ''
    if ($obj -and $obj.PSObject.Properties['conversation_id']) { $cid = [string]$obj.conversation_id }
    $cid = $cid -replace '[^\w\-]', ''
    if (-not $cid) { return 'default' }
    return $cid
}

function Get-HooksPendingDir {
    return Join-Path $HOME '.cursor\.hooks-pending'
}

function Test-IsCursorConfigPath([string]$path) {
    if (-not $path) { return $false }
    return ($path -match '(^|[\\/])\.cursor([\\/]|$)')
}

function ConvertTo-FwdPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim()
    if ($p -match '^/([A-Za-z]):?(/.*)$') { $p = $Matches[1] + ':' + $Matches[2] }
    return $p.Replace('\', '/')
}
