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

# Expand ~/ in agent-facing text to an absolute profile path. pwsh and many
# agent tools do not resolve ~ on Windows; stop-hook followups must be literal.
function Expand-AgentPaths([string]$text) {
    if (-not $text) { return $text }
    $homeFwd = $HOME.TrimEnd('\', '/').Replace('\', '/')
    return $text.Replace('~/', "$homeFwd/")
}

# Normalize a file path for agent prompts (expand ~, forward slashes).
function Resolve-AgentPath([string]$p) {
    if (-not $p) { return $p }
    $p = $p.Trim()
    if ($p -match '^~[\\/]') {
        $p = Join-Path $HOME ($p.Substring(2))
    }
    if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if ($resolved) { return ConvertTo-FwdPath $resolved.Path }
    }
    return ConvertTo-FwdPath $p
}

# Extract the last user <user_query> from a Cursor transcript JSONL. The
# transcript is an array of {role, message} records; we walk backward from the
# end, find the last user turn whose content has a <user_query> tag, and return
# its text. Returns '' if there is no transcript or no user_query. Capped at
# 2000 chars so the follow-up prompt stays bounded.
#
# This is the Tier 0 intent-trace primitive: the final-review hook prepends the
# extracted request to its followup so the model must trace every diff hunk back
# to it. Anything untraceable is a hallucinated requirement.
function Get-LastUserQuery($obj) {
    $tp = ''
    if ($obj -and $obj.PSObject.Properties['transcript_path']) { $tp = [string]$obj.transcript_path }
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return '' }
    $lines = @(Get-Content -LiteralPath $tp -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line -or $line -notmatch '"role"\s*:\s*"user"') { continue }
        try {
            $rec = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        } catch { continue }
        if (-not $rec -or -not $rec.message) { continue }
        $content = $rec.message.content
        if (-not $content) { continue }
        # content is an array of {type:text,text:...} or a plain string
        $text = ''
        if ($content -is [string]) {
            $text = $content
        } else {
            foreach ($part in $content) {
                if ($part.type -eq 'text' -and $part.text) { $text += $part.text }
            }
        }
        if ($text -match '(?s)<user_query>\s*(.+?)\s*</user_query>') {
            $q = $Matches[1].Trim()
            if ($q.Length -gt 2000) { $q = $q.Substring(0, 2000) + '...' }
            return $q
        }
    }
    return ''
}

# Subagent edits fire afterFileEdit under the SUBAGENT's conversation_id, so
# their session-edits markers are invisible to the parent's stop-hook review.
# Subagent transcripts live at <transcripts>/<parent-cid>/subagents/<sub-cid>.jsonl,
# which gives a deterministic parent->subagent mapping: fold each subagent's
# marker into the parent's and remove the original. Returns $true if anything
# was folded. No-ops when called from a subagent context (its transcript_path
# has no sibling 'subagents' dir).
function Merge-SubagentEditMarkers($obj, [string]$parentCid) {
    $tp = ''
    if ($obj -and $obj.PSObject.Properties['transcript_path']) { $tp = [string]$obj.transcript_path }
    if (-not $tp) { return $false }
    $subDir = Join-Path (Split-Path $tp -Parent) 'subagents'
    if (-not (Test-Path $subDir)) { return $false }
    $pendingDir = Get-HooksPendingDir
    $parentMarker = Join-Path $pendingDir "session-edits-$parentCid.txt"
    $folded = $false
    foreach ($j in Get-ChildItem $subDir -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
        $scid = [System.IO.Path]::GetFileNameWithoutExtension($j.Name) -replace '[^\w\-]', ''
        if (-not $scid -or $scid -eq $parentCid) { continue }
        $m = Join-Path $pendingDir "session-edits-$scid.txt"
        if (-not (Test-Path $m)) { continue }
        New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
        $lines = @(Get-Content $m -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
        if ($lines.Count -eq 0) { continue }
        $lines | Add-Content -Path $parentMarker -ErrorAction SilentlyContinue
        Remove-Item $m -Force -ErrorAction SilentlyContinue
        $folded = $true
    }
    return $folded
}
