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

function ConvertTo-ScopeRelativePath([string]$path, [string]$root) {
    $p = ConvertTo-FwdPath $path
    if (-not $p) { return '' }
    $rootFwd = (ConvertTo-FwdPath $root).TrimEnd('/')
    if (-not $rootFwd) { return '' }

    $isAbs = ($p -match '^[A-Za-z]:/') -or $p.StartsWith('/')
    if ($isAbs) {
        if (-not $p.StartsWith($rootFwd + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
        $p = $p.Substring($rootFwd.Length + 1)
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($p -split '/')) {
        if (-not $part -or $part -eq '.') { continue }
        if ($part -eq '..') { return '' }
        $parts.Add($part) | Out-Null
    }
    return ($parts -join '/')
}

# Resolve the project root for an event: cwd -> workspace_roots ->
# CURSOR_PROJECT_DIR -> $PWD (if it looks like a project root). The $PWD
# fallback exists because Cursor's beforeSubmitPrompt event does NOT include
# cwd in its payload — the hook process's working directory IS the project
# root in that case. The project-marker guard prevents writing .scope.json to
# $HOME or random dirs (this was the cause of the ghost .scope.json in
# AppData\Local\Lemonade). Any git repo OR any dir with a recognized project
# marker file is accepted, so this works for non-git repos too.
$PROJECT_MARKERS = @(
    '.git', '.hg', '.svn',
    'package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'setup.py',
    'pom.xml', 'build.gradle', 'build.gradle.kts', 'Gemfile', 'composer.json',
    'Makefile', 'CMakeLists.txt', '.project', 'tsconfig.json'
)
function Test-ProjectRoot([string]$dir) {
    foreach ($m in $PROJECT_MARKERS) {
        if (Test-Path -LiteralPath (Join-Path $dir $m)) { return $true }
    }
    return $false
}
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
    # to the project root. Accept if it's a git repo OR has a project marker —
    # no ghost files.
    if (-not $root) {
        $pwdFwd = (Get-Location).Path.Replace('\', '/').TrimEnd('/')
        if ($pwdFwd -and (Test-ProjectRoot $pwdFwd)) { $root = $pwdFwd }
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
# Last <user_query> text from the transcript, including hook-generated turns.
# Used by final-review to detect whether the review follow-up just completed.
function Get-LastRawUserQueryText($obj) {
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
        $text = ''
        if ($content -is [string]) {
            $text = $content
        } else {
            foreach ($part in $content) {
                if ($part.type -eq 'text' -and $part.text) { $text += $part.text }
            }
        }
        if ($text -match '(?s)<user_query>\s*(.+?)\s*</user_query>') {
            return $Matches[1].Trim()
        }
    }
    return ''
}

function Write-FinalReviewDebug([string]$reason) {
    if ($env:FINAL_REVIEW_DEBUG -ne '1' -or -not $reason) { return }
    $dir = Join-Path $HOME '.cursor\.hooks-pending'
    $log = Join-Path $dir 'last-final-review.log'
    try {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        $ts = Get-Date -Format 'o'
        Add-Content -LiteralPath $log -Value "$ts $reason" -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
}

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

# Scrape the most recent ACCEPT/REVISE verdict from assistant turns in the
# transcript. Returns $null if none. Used by milestone-verify (postToolUse) to
# record the agent's per-step verdict into .scope.json's verifications[] without
# requiring the agent to write the file itself. Walks backward through assistant
# records; the first match (most recent) wins.
#
# Pattern set (canonical first, then loosened phrasings). The canonical
# "ACCEPT step N" / "REVISE step N" form is still the doctrine-taught phrasing
# and stays the primary match so existing transcripts and verify() fixtures
# scrape unchanged. The loosened alternates catch casual model phrasings
# ("step N looks good", "step N accepted", "step N needs work") that previously
# left verifications[] blank. First regex to match (in order) wins; verdict verb
# is normalized to ACCEPT/REVISE before writing.
function Get-LastVerdict($obj) {
    $tp = ''
    if ($obj -and $obj.PSObject.Properties['transcript_path']) { $tp = [string]$obj.transcript_path }
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return $null }
    $lines = @(Get-Content -LiteralPath $tp -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line -or $line -notmatch '"role"\s*:\s*"assistant"') { continue }
        try {
            $rec = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        } catch { continue }
        if (-not $rec) { continue }
        $msg = $rec.message
        if (-not $msg) { $msg = $rec }
        $content = $msg.content
        if (-not $content) { continue }
        $text = ''
        if ($content -is [string]) {
            $text = $content
        } else {
            foreach ($part in $content) {
                if ($part.type -eq 'text' -and $part.text) { $text += $part.text }
            }
        }
        if (-not $text) { continue }

        # Canonical: ACCEPT step N [: diagnosis] / REVISE step N [: diagnosis]
        if ($text -match '(?mi)\b(ACCEPT|REVISE)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?\s*$') {
            $verdict = $Matches[1].ToUpperInvariant()
            try { $stepNum = [int]$Matches[2] } catch { continue }
            $diag = ''
            if ($Matches.Count -ge 4 -and $Matches[3]) { $diag = ([string]$Matches[3]).Trim() }
            return @{ verdict = $verdict; step = $stepNum; diagnosis = $diag }
        }
        # Loosened: "ACCEPTED step N" / "REVISED step N"
        if ($text -match '(?mi)\b(ACCEPTED|REVISED)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?\s*$') {
            $verb = $Matches[1].ToUpperInvariant()
            $verdict = if ($verb -eq 'ACCEPTED') { 'ACCEPT' } else { 'REVISE' }
            try { $stepNum = [int]$Matches[2] } catch { continue }
            $diag = ''
            if ($Matches.Count -ge 4 -and $Matches[3]) { $diag = ([string]$Matches[3]).Trim() }
            return @{ verdict = $verdict; step = $stepNum; diagnosis = $diag }
        }
        # Loosened: "step N <accepting-phrase>" — accept/approve/done/complete/good/ok/pass
        if ($text -match '(?mi)\bstep\s+(\d+)\s+(accepted|approved|done|complete[ds]?|looks good|good|ok|passes?|passed)\b') {
            try { $stepNum = [int]$Matches[1] } catch { continue }
            return @{ verdict = 'ACCEPT'; step = $stepNum; diagnosis = '' }
        }
        # Loosened: "step N <rejecting-phrase>" — revise/fail/broken/needs fix
        if ($text -match '(?mi)\bstep\s+(\d+)\s+(revise[ds]?|needs?\s+fix|fails?|failed|broken|reject(?:ed)?)\b') {
            try { $stepNum = [int]$Matches[1] } catch { continue }
            return @{ verdict = 'REVISE'; step = $stepNum; diagnosis = '' }
        }
    }
    return $null
}
