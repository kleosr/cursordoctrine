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

# SHA-256 hex of a string. SHARED so intent-precompile (beforeSubmitPrompt) and
# intent-anchor (postToolUse) hash the SAME text the SAME way - otherwise the two
# disagree on the contract's _intent_hash and the postToolUse hook needlessly
# regenerates the scope the prompt hook just wrote.
function Get-Sha256Hex([string]$text) {
    if ($null -eq $text) { $text = '' }
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    return (-join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
}

# Path where the beforeSubmitPrompt hook stashes the verbatim user prompt for the
# turn, keyed by conversation. intent-anchor PREFERS this over transcript parsing:
# it is the ground-truth request captured directly from the payload (no <user_query>
# extraction, no hook-followup contamination, available on the FIRST postToolUse
# of the turn instead of whenever the transcript happens to become readable).
function Get-CurrentPromptPath([string]$cid) {
    return Join-Path (Get-HooksPendingDir) "current-prompt-$cid.txt"
}

# Read the stashed prompt for this conversation ('' if none). The stash only ever
# holds real human prompts - intent-precompile filters hook-generated submits.
function Get-StashedPrompt([string]$cid) {
    $p = Get-CurrentPromptPath $cid
    if (Test-Path -LiteralPath $p) {
        $t = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
        if ($t) { return $t.TrimEnd("`r", "`n") }
    }
    return ''
}

# Default acceptance the hook seeds so .scope.json NEVER ships a bare "<TODO>"
# placeholder (the thing that looks broken and never gets filled). It is a real,
# verifiable bar derived from intent; the agent sharpens it to the single
# deterministic check. Kept in ONE place so both hooks emit the identical string.
function Get-DefaultAcceptance {
    return 'Every change traces to intent; the project typecheck/build and any *.selfcheck pass, and the described problem no longer reproduces. (Sharpen to the one deterministic check.)'
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

# Strip secrets from text before embedding in agent-facing followups. Intent
# trace must not re-broadcast tokens the user pasted in chat.
function Redact-SecretsFromIntent([string]$text) {
    if (-not $text) { return $text }
    $text = $text -replace '\bnpm_[A-Za-z0-9]{10,}\b', '[REDACTED_NPM_TOKEN]'
    $text = $text -replace '\b(sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,})\b', '[REDACTED_TOKEN]'
    $text = $text -replace '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*\S+', '$1=[REDACTED]'
    return $text
}

# A <user_query> turn can actually be a HOOK-GENERATED message replayed by Cursor
# as a user turn: final-review.ps1 and subagent-stop-review.ps1 emit a
# {followup_message} that Cursor auto-submits as the next user turn, and the
# self-review / intent-anchor injections get drained into additional_context.
# If Get-LastUserQuery returns one of those, intent-anchor locks the REVIEW
# BOILERPLATE into .scope.json as the "intent" (the contamination loop that put
# "FINAL REVIEW (end of implementation)..." in the contract). Detect them by the
# fixed headers the hooks emit and skip past them to the real human turn.
function Test-IsHookGeneratedQuery([string]$text) {
    if (-not $text) { return $false }
    return ($text -match '(?m)^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR)')
}

# The final-review / subagent-review followups embed the real human request as:
#   ORIGINAL REQUEST (...):\n---\n<request>\n---
# When the transcript has been trimmed to just the hook turn, recover the human
# request from that block instead of returning the boilerplate.
function Get-EmbeddedOriginalRequest([string]$text) {
    if (-not $text) { return '' }
    if ($text -match '(?s)ORIGINAL REQUEST[^\r\n]*\r?\n-{3,}\r?\n(.+?)\r?\n-{3,}') {
        return $Matches[1].Trim()
    }
    return ''
}

# Extract the last *human* user <user_query> from a Cursor transcript JSONL.
# transcript is an array of {role, message} records; we walk backward from the
# end, skipping hook-generated turns (see above), and return the first real human
# turn's text. Returns '' if there is no transcript or no human user_query. Capped
# at 2000 chars so the follow-up prompt stays bounded.
#
# This is the Tier 0 intent-trace primitive: the final-review hook prepends the
# extracted request to its followup so the model must trace every diff hunk back
# to it. Anything untraceable is a hallucinated requirement.
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
            # Hook-generated turn -> not the human's words. Remember the embedded
            # ORIGINAL REQUEST (from the most recent such turn) and keep walking.
            if (Test-IsHookGeneratedQuery $q) {
                if (-not $embeddedFallback) { $embeddedFallback = Get-EmbeddedOriginalRequest $q }
                continue
            }
            if ($q.Length -gt 2000) { $q = $q.Substring(0, 2000) + '...' }
            return (Redact-SecretsFromIntent $q)
        }
    }
    # No real human turn survived in the transcript -> fall back to the request
    # embedded in the latest hook followup, if we found one.
    if ($embeddedFallback) {
        if ($embeddedFallback.Length -gt 2000) { $embeddedFallback = $embeddedFallback.Substring(0, 2000) + '...' }
        return (Redact-SecretsFromIntent $embeddedFallback)
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
