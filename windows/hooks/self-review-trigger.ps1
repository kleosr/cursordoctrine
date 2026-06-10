# self-review-trigger.ps1 - afterFileEdit for Cursor.
#
# Single responsibility: when the model just edited a file, hand the
# edit context to the NEXT model turn as additional_context. The model
# is the auditor; the harness is just the message bus.
#
# This is intentionally minimal:
#   - We do NOT parse the diff ourselves.
#   - We do NOT spawn a sub-agent.
#   - We do NOT write to .stuck-files/.
#   - We do NOT block.
#
# We DO:
#   - Capture the edited file path.
#   - Stash a self-review prompt that primes the model's next turn.
#   - Exit 0 always.
#
# Cursor's afterFileEdit doesn't consume its own output. To actually
# surface the message, post-tool-use.ps1 re-emits it on the next tool
# boundary. See hooks.json.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

$inputText = Read-HookStdin

$filePath = ''
$cid = ''
if ($inputText) {
    try {
        $obj = $inputText | ConvertFrom-Json
        if ($obj) {
            if     ($obj.PSObject.Properties['file_path']) { $filePath = [string]$obj.file_path }
            elseif ($obj.PSObject.Properties['path'])      { $filePath = [string]$obj.path }
            elseif ($obj.PSObject.Properties['filePath'])  { $filePath = [string]$obj.filePath }
            $cid = Get-SafeConversationId $obj
        }
    } catch {
        $filePath = ''
    }
}

# Empty path (JSON parse failed, or no file_path field) -> nothing to record.
# Without this guard the .cursor regex below doesn't match '' and we append a
# blank line to the session-edits marker on every such fire (it accumulates fast).
if (-not $filePath) { exit 0 }
if (Test-IsCursorConfigPath $filePath) { exit 0 }

# State is keyed by conversation_id and lives under $HOME, never the project:
# no repo litter, works in workspace-less sessions (CURSOR_PROJECT_DIR/
# workspace_roots are empty there), and concurrent sessions cannot drain each
# other's prompts.
$pendingDir = Get-HooksPendingDir

# Record this edit for the end-of-implementation review. The stop hook
# (final-review.ps1) drains this marker to fire one final review pass over
# everything changed this agent loop. Append = running list of edits.
try {
    $mk = Join-Path $pendingDir "session-edits-$cid.txt"
    New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    Add-Content -Path $mk -Value $filePath
} catch { }

$doctrineFile = Join-Path $HOME '.agents\hooks\self-review.md'
if (-not (Test-Path $doctrineFile)) { exit 0 }
$doctrine = Get-Content $doctrineFile -Raw

$msg = "SELF-REVIEW TRIGGER - you just edited: $filePath`n`n$doctrine"

$pendingFile = Join-Path $pendingDir "feedback-$cid.txt"

try {
    New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    $prefix = ''
    if ((Test-Path $pendingFile) -and ((Get-Item $pendingFile).Length -gt 0)) {
        $prefix = "`n`n---`n`n"
    }
    Add-Content -Path $pendingFile -Value ($prefix + $msg) -NoNewline
} catch {
    # Silently fail open
}

exit 0
