# hook-common.ps1 - shared helpers for Cursor agent hooks.
# Dot-source from sibling scripts: . "$PSScriptRoot\hook-common.ps1"
#
# Minimal: only what final-review.ps1 and inject-doctrine.ps1 actually use.
# No state directory, no .scope.json bookkeeping, no subagent folding.

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

# ASCII-only JSON to stdout, immune to [Console]::OutputEncoding mangling.
# Non-ASCII chars escape to \uXXXX so output is byte-identical under any encoding.
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
    # Fall back to transcript_path basename — unique per conversation, prevents
    # cross-session brake interference when conversation_id is absent.
    if (-not $cid -and $obj -and $obj.PSObject.Properties['transcript_path']) {
        $tp = [string]$obj.transcript_path
        if ($tp) { $cid = [System.IO.Path]::GetFileNameWithoutExtension($tp) }
    }
    $cid = $cid -replace '[^\w\-]', ''
    if (-not $cid) { return 'default' }
    return $cid
}

function ConvertTo-FwdPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim()
    if ($p -match '^/([A-Za-z]):?(/.*)$') { $p = $Matches[1] + ':' + $Matches[2] }
    return $p.Replace('\', '/')
}

# Resolve the project root for an event: cwd -> workspace_roots ->
# CURSOR_PROJECT_DIR -> $PWD (if it's a git repo). The $PWD fallback exists
# because Cursor's beforeSubmitPrompt event does NOT include cwd in its
# payload — the hook process's working directory IS the project root in that
# case. The git-repo guard prevents writing .scope.json to $HOME or random dirs
# (this was the cause of the ghost .scope.json in AppData\Local\Lemonade).
function Resolve-ProjectRoot($obj) {
    $root = ''
    $cands = @()
    if ($obj -and $obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
    if ($obj -and $obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
    foreach ($c in $cands) {
        $f = ConvertTo-FwdPath $c
        if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break }
    }
    if (-not $root -and $env:CURSOR_PROJECT_DIR) {
        $cpd = $env:CURSOR_PROJECT_DIR.Replace('\', '/').TrimEnd('/')
        if (Test-Path -LiteralPath $cpd) { $root = $cpd }
    }
    # Fallback: process working directory. Cursor launches hooks with CWD set
    # to the project root. Only accept if it's a git repo — no ghost files.
    if (-not $root) {
        $pwdFwd = (Get-Location).Path.Replace('\', '/').TrimEnd('/')
        if ($pwdFwd) {
            & git -C $pwdFwd rev-parse --git-dir 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $root = $pwdFwd }
        }
    }
    return $root
}

# Expand ~/ in agent-facing text to an absolute profile path.
function Expand-AgentPaths([string]$text) {
    if (-not $text) { return $text }
    $homeFwd = $HOME.TrimEnd('\', '/').Replace('\', '/')
    return $text.Replace('~/', "$homeFwd/")
}

function Resolve-AgentPath([string]$p) {
    if (-not $p) { return $p }
    $p = $p.Trim()
    if ($p -match '^~[\\/]') { $p = Join-Path $HOME ($p.Substring(2)) }
    return (ConvertTo-FwdPath $p)
}

# Strip secrets before re-broadcasting a user prompt in a followup.
function Redact-SecretsFromIntent([string]$text) {
    if (-not $text) { return $text }
    $text = $text -replace '\bnpm_[A-Za-z0-9]{10,}\b', '[REDACTED_NPM_TOKEN]'
    $text = $text -replace '\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b', '[REDACTED_TOKEN]'
    $text = $text -replace '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+', '$1=[REDACTED]'
    return $text
}

# A <user_query> turn can be a HOOK-GENERATED message Cursor replays as a user
# turn (final-review's own {followup_message}). Detect those by their fixed
# headers and skip past them so we return the real human turn, not boilerplate.
function Test-IsHookGeneratedQuery([string]$text) {
    if (-not $text) { return $false }
    return ($text -match '(?m)^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED)')
}

# Recover the human request embedded in a hook followup
# ("ORIGINAL REQUEST (...):\n---\n<request>\n---") when the transcript has been
# trimmed to just the hook turn.
function Get-EmbeddedOriginalRequest([string]$text) {
    if (-not $text) { return '' }
    if ($text -match '(?s)ORIGINAL REQUEST[^\r\n]*\r?\n-{3,}\r?\n(.+?)\r?\n-{3,}') {
        return $Matches[1].Trim()
    }
    return ''
}

# Extract the last *human* user <user_query> from a Cursor transcript JSONL.
# Walks backward, skipping hook-generated turns. Returns '' if none.
# This is the intent-trace primitive: the final-review followup prepends it so
# the model must tie every diff hunk to a concrete request. Anything untraceable
# is a hallucinated requirement.
function Get-LastUserQuery($obj) {
    $tp = ''
    if ($obj -and $obj.PSObject.Properties['transcript_path']) { $tp = [string]$obj.transcript_path }
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return '' }
    $lines = @(Get-Content -LiteralPath $tp -ErrorAction SilentlyContinue)
    $embeddedFallback = ''
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line -or $line -notmatch '"role"\s*:\s*"user"') { continue }
        try {
            $rec = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        } catch { continue }
        if (-not $rec -or -not $rec.message) { continue }
        $content = $rec.message.content
        if (-not $content) { continue }
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
            if (Test-IsHookGeneratedQuery $q) {
                if (-not $embeddedFallback) { $embeddedFallback = Get-EmbeddedOriginalRequest $q }
                continue
            }
            if ($q.Length -gt 2000) { $q = $q.Substring(0, 2000) + '...' }
            return (Redact-SecretsFromIntent $q)
        }
    }
    if ($embeddedFallback) {
        if ($embeddedFallback.Length -gt 2000) { $embeddedFallback = $embeddedFallback.Substring(0, 2000) + '...' }
        return (Redact-SecretsFromIntent $embeddedFallback)
    }
    return ''
}
