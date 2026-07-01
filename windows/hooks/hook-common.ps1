# hook-common.ps1 - shared helpers for Cursor agent hooks.
# Dot-source from sibling scripts: . "$PSScriptRoot\hook-common.ps1"
#
# Shared by all hooks in this pack. JSON parsing uses native ConvertFrom-Json.

$DefaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

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

function Get-SessionStampPath($obj) {
    $cid = Get-SafeConversationId $obj
    return Join-Path $HOME ".cursor\.hooks-pending\session-start-$cid.txt"
}

function Write-SessionStartStamp($obj) {
    if (-not $obj) { return }
    $stampPath = Get-SessionStampPath $obj
    $pendingDir = Split-Path -Parent $stampPath
    New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Set-Content -LiteralPath $stampPath -Value $ts -NoNewline -ErrorAction SilentlyContinue
}

function Ensure-SessionStartStamp($obj) {
    $stampPath = Get-SessionStampPath $obj
    if (Test-Path -LiteralPath $stampPath) { return }
    Write-SessionStartStamp $obj
}

function Get-SessionStartUtc($obj) {
    $stampPath = Get-SessionStampPath $obj
    if (-not (Test-Path -LiteralPath $stampPath)) { return $null }
    try {
        $raw = (Get-Content -LiteralPath $stampPath -Raw).Trim()
        return [DateTimeOffset]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    } catch { return $null }
}

function Test-PathModifiedSinceSession([string]$fullPath, $obj) {
    $sessionStart = Get-SessionStartUtc $obj
    if (-not $sessionStart) { return $false }
    if (-not (Test-Path -LiteralPath $fullPath)) { return $false }
    try {
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $sessionEpoch = [int][DateTimeOffset]::new($sessionStart).ToUnixTimeSeconds() - 1
        $fileEpoch = [int][DateTimeOffset]::new($item.LastWriteTimeUtc).ToUnixTimeSeconds()
        return $fileEpoch -ge $sessionEpoch
    } catch { return $false }
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

function Get-WorkspaceRoots($obj) {
    $roots = New-Object System.Collections.Generic.List[string]
    if ($obj -and $obj.PSObject.Properties['cwd'] -and $obj.cwd) {
        $f = ConvertTo-FwdPath ([string]$obj.cwd)
        if ($f -and (Test-Path -LiteralPath $f)) { $roots.Add($f.TrimEnd('/')) | Out-Null }
    }
    if ($obj -and $obj.PSObject.Properties['workspace_roots'] -and $obj.workspace_roots) {
        foreach ($w in $obj.workspace_roots) {
            $f = ConvertTo-FwdPath ([string]$w)
            if ($f -and (Test-Path -LiteralPath $f)) {
                $norm = $f.TrimEnd('/')
                if (-not $roots.Contains($norm)) { $roots.Add($norm) | Out-Null }
            }
        }
    }
    return @($roots.ToArray())
}

function ConvertTo-ScopeRelativePathAnyRoot([string]$path, $obj) {
    foreach ($root in (Get-WorkspaceRoots $obj)) {
        $rel = ConvertTo-ScopeRelativePath $path $root
        if ($rel) { return $rel }
    }
    $fallback = Resolve-ProjectRoot $obj
    if ($fallback) { return ConvertTo-ScopeRelativePath $path $fallback }
    return ''
}

function Test-IsPlanArtifactPath([string]$path) {
    $p = ConvertTo-FwdPath $path
    if (-not $p) { return $false }
    $p = $p.TrimStart('/')
    return ($p -ieq '.cursor/plans' -or $p.StartsWith('.cursor/plans/', [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-IsPlanModeEvent($obj) {
    if (-not $obj) { return $false }
    foreach ($k in @('composer_mode', 'composerMode', 'agent_mode', 'agentMode', 'cursor_mode', 'cursorMode', 'chat_mode', 'chatMode', 'mode')) {
        if ($obj.PSObject.Properties[$k] -and $obj.$k) {
            $v = ([string]$obj.$k).Trim().ToLowerInvariant()
            if ($v -match '^(plan|planning|plan_mode|planning_mode)$') { return $true }
        }
    }
    foreach ($k in @('is_plan_mode', 'isPlanMode', 'planning')) {
        if ($obj.PSObject.Properties[$k]) {
            $raw = $obj.$k
            if ($raw -is [bool] -and $raw) { return $true }
            $v = ([string]$raw).Trim().ToLowerInvariant()
            if ($v -in @('true', '1', 'yes')) { return $true }
        }
    }
    return $false
}

function Test-IsPlanOnlyPrompt([string]$text) {
    if (-not $text) { return $false }
    $implementation = '(?i)\b(implement|build|fix|edit|modify|change|patch|apply|code|ship|execute|wire|refactor|update|make this work|do it)\b'
    if ($text -match $implementation) { return $false }
    if ($text -match '(?i)<proposed_plan>') { return $true }
    if ($text -match '(?i)\b(plan mode|planning mode)\b') { return $true }
    if ($text -match '(?i)\b(write|draft|propose|produce|generate|outline|create|make)\b.{0,80}\b(plan|implementation plan|spec)\b') { return $true }
    if ($text -match '(?i)\b(plan|spec)\b.{0,80}\b(only|first|before implementation|before coding)\b') { return $true }
    return $false
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
    return ($text -match '(?m)^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER|VERIFY MILESTONE)')
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

function Get-ContentText($content) {
    if (-not $content) { return '' }
    if ($content -is [string]) { return $content }
    $text = ''
    foreach ($part in $content) {
        if ($part.type -eq 'text' -and $part.text) { $text += $part.text }
    }
    return $text
}

# Last <user_query> text from the transcript, including hook-generated turns.
# Used by final-review to detect whether the review follow-up just completed.
function Get-LastRawUserQueryText($obj) {
    return Get-LastUserQuery $obj -IncludeHookGenerated
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

# Atomic, crash-safe .scope.json write: serializes concurrent writers with a
# short-retry lock sentinel, write to a temp file, then rename over the target.
# Serializes the write only — callers that read-modify-write outside this lock
# can still lose updates; use Update-ScopeJson for full RMW inside the lock.
# ponytail: lock ceiling = stale sentinel left by a hard-killed process is swept
# after 10s; not a true OS mutex. Upgrade = named mutex keyed on the file path.
function Write-ScopeJsonAtomic([string]$path, [string]$json) {
    if (-not $path) { return }
    # Refuse empty content: an empty .scope.json is always a transform failure,
    # never a valid state. Guarding here makes truncation impossible even if a
    # caller forgets to check the transform output before writing.
    if (-not $json) { return }
    $dir = Split-Path -Parent $path
    if (-not $dir) { return }
    $lock = "$path.lock"
    $stale = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
    if ($stale -and ((Get-Date) - $stale.LastWriteTime).TotalSeconds -gt 10) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
    $fs = $null
    $acquired = $false
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $acquired = $true
            break
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    if (-not $acquired) { return }
    try {
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        # Move-Item -Force does an atomic rename-with-overwrite on the same
        # volume (MoveFileEx MOVEFILE_REPLACE_EXISTING). File.Replace rejects a
        # null backup name on this .NET and File.Move refuses an existing dest.
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath "$path.tmp" -Force -ErrorAction SilentlyContinue
    } finally {
        if ($fs) { $fs.Close() }
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

function Acquire-ScopeJsonLock([string]$path) {
    $lock = "$path.lock"
    $stale = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
    if ($stale -and ((Get-Date) - $stale.LastWriteTime).TotalSeconds -gt 10) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            return $fs
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    return $null
}

function Release-ScopeJsonLock($fs, [string]$path) {
    if ($fs) { $fs.Close() }
    Remove-Item -LiteralPath "$path.lock" -Force -ErrorAction SilentlyContinue
}

function Update-ScopeJson([string]$path, [scriptblock]$transform) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    $fs = Acquire-ScopeJsonLock $path
    if (-not $fs) { return $false }
    try {
        $sj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $updated = & $transform $sj
        if ($updated) { $sj = $updated }
        $ordered = [ordered]@{}
        foreach ($p in $sj.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
        $json = $ordered | ConvertTo-Json -Depth 8
        if (-not $json) { return $false }
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -LiteralPath "$path.tmp" -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Release-ScopeJsonLock $fs $path
    }
}

function Merge-ScopeFiles($existing, $newPaths, [string]$root) {
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($existing)) {
        $s = [string]$e
        if (-not $s -or $s -match '^\s*<TODO' -or [string]::IsNullOrWhiteSpace($s) -or ($s.Trim() -ieq '.scope.json')) { continue }
        if (Test-IsPlanArtifactPath $s) { continue }
        $kept.Add($s) | Out-Null
    }
    $appended = $false
    foreach ($p in @($newPaths)) {
        $rel = ConvertTo-ScopeRelativePath ([string]$p) $root
        if (-not $rel -or $rel -ieq '.scope.json') { continue }
        if (Test-IsPlanArtifactPath $rel) { continue }
        $already = $false
        foreach ($f in $kept) {
            if (([string]$f).Replace('\', '/').TrimStart('/') -ieq $rel) { $already = $true; break }
        }
        if (-not $already) {
            $kept.Add($rel) | Out-Null
            $appended = $true
        }
    }
    $changed = $appended
    if (-not $changed) {
        $existingList = @($existing)
        if ($kept.Count -ne $existingList.Count) { $changed = $true }
        else {
            for ($i = 0; $i -lt $kept.Count; $i++) {
                if ([string]$kept[$i] -ne [string]$existingList[$i]) { $changed = $true; break }
            }
        }
    }
    return @{ Files = @($kept.ToArray()); Appended = $appended; Changed = $changed }
}

function Read-NudgeFlag([string]$flagPath) {
    $lastCount = -1
    $nudgeCount = 0
    if (Test-Path -LiteralPath $flagPath) {
        try {
            $parts = (Get-Content $flagPath -Raw -ErrorAction SilentlyContinue).Trim() -split ':'
            if ($parts.Count -ge 1) { $lastCount = [int]$parts[0] }
            if ($parts.Count -ge 2) { $nudgeCount = [int]$parts[1] }
        } catch { }
    }
    return @{ LastCount = $lastCount; NudgeCount = $nudgeCount }
}

function Write-NudgeFlag([string]$flagPath, [int]$filesCount, [int]$nudgeCount) {
    $pendingDir = Split-Path -Parent $flagPath
    New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -LiteralPath $flagPath -Value "${filesCount}:${nudgeCount}" -ErrorAction SilentlyContinue
}

# Extract the last *human* user <user_query> from a Cursor transcript JSONL.
# Walks backward, skipping hook-generated turns. Returns '' if none.
# This is the intent-trace primitive: the final-review followup prepends it so
# the model must tie every diff hunk to a concrete request. Anything untraceable
# is a hallucinated requirement.
function Get-LastUserQuery($obj, [switch]$IncludeHookGenerated) {
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
        $text = Get-ContentText $rec.message.content
        if ($text -match '(?s)<user_query>\s*(.+?)\s*</user_query>') {
            $q = $Matches[1].Trim()
            if ($IncludeHookGenerated) { return $q }
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
# records; the first turn with a verdict wins. Within that turn, the RIGHTMOST
# verdict wins (the model may revise "ACCEPT" -> "REVISE" in one message).
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
        $text = Get-ContentText $msg.content
        if (-not $text) { continue }
        $v = Get-LastVerdictFromText $text
        if ($v) { return $v }
    }
    return $null
}

# Returns the rightmost verdict in a single assistant turn's text, or $null.
# Strips fenced code blocks first so verdict keywords shown inside examples or
# quoted output are not scraped as real verdicts. Collects every match of the
# canonical, ACCEPTED/REVISED, and loosened step-N phrasings, then picks the one
# with the largest start index — the last verdict the model uttered.
function Get-LastVerdictFromText([string]$text) {
    if (-not $text) { return $null }
    # Skip final-review report turns so axis lines like "- **7 Role-trace**: FAIL - step 2..."
    # are not scraped as real verdicts. The report contains a mandatory **Verdict** marker.
    if ($text -match '\*\*Verdict\*\*:') { return $null }
    $stripped = [regex]::Replace($text, '(?s)```.*?```', '')
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($stripped, '(?im)\b(ACCEPT|REVISE)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?(?=\s*$|\r?\n)')) {
        try { $sn = [int]$m.Groups[2].Value } catch { continue }
        $diag = if ($m.Groups[3].Success) { ([string]$m.Groups[3].Value).Trim() } else { '' }
        $candidates.Add([pscustomobject]@{ Index = $m.Index; Verdict = $m.Groups[1].Value.ToUpperInvariant(); Step = $sn; Diagnosis = $diag })
    }
    foreach ($m in [regex]::Matches($stripped, '(?im)\b(ACCEPTED|REVISED)\s+step\s+(\d+)(?:\s*[:\-]\s*(.+?))?(?=\s*$|\r?\n)')) {
        try { $sn = [int]$m.Groups[2].Value } catch { continue }
        $verb = $m.Groups[1].Value.ToUpperInvariant()
        $vd = if ($verb -eq 'ACCEPTED') { 'ACCEPT' } else { 'REVISE' }
        $diag = if ($m.Groups[3].Success) { ([string]$m.Groups[3].Value).Trim() } else { '' }
        $candidates.Add([pscustomobject]@{ Index = $m.Index; Verdict = $vd; Step = $sn; Diagnosis = $diag })
    }
    foreach ($m in [regex]::Matches($stripped, '(?i)\bstep\s+(\d+)\s+(accepted|approved|done|complete[ds]?|looks good|good|ok|passes?|passed)\b')) {
        try { $sn = [int]$m.Groups[1].Value } catch { continue }
        $candidates.Add([pscustomobject]@{ Index = $m.Index; Verdict = 'ACCEPT'; Step = $sn; Diagnosis = '' })
    }
    foreach ($m in [regex]::Matches($stripped, '(?i)\bstep\s+(\d+)\s+(revise[ds]?|needs?\s+fix|fails?|failed|broken|reject(?:ed)?)\b')) {
        try { $sn = [int]$m.Groups[1].Value } catch { continue }
        $candidates.Add([pscustomobject]@{ Index = $m.Index; Verdict = 'REVISE'; Step = $sn; Diagnosis = '' })
    }
    if ($candidates.Count -eq 0) { return $null }
    $last = $candidates | Sort-Object Index -Descending | Select-Object -First 1
    return @{ verdict = $last.Verdict; step = $last.Step; diagnosis = $last.Diagnosis }
}
