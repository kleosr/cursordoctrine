# post-tool-use.ps1 - postToolUse for Cursor.
#
# Single responsibility: drain this conversation's stashed self-review /
# advisory messages into Cursor's additional_context channel. One-shot
# delivery, keyed by conversation_id so concurrent sessions never receive
# each other's prompts.
#
# We do not parse, score, or filter. We do not run any audit. We do not
# block. The model that already produced the edit will, on its next
# turn, do the self-review.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

$obj = Read-HookStdinJson
$cid = Get-SafeConversationId $obj

$pendingFile = Join-Path (Get-HooksPendingDir) "feedback-$cid.txt"

if (-not (Test-Path $pendingFile)) { exit 0 }
if ((Get-Item $pendingFile).Length -le 0) {
    Remove-Item $pendingFile -Force -ErrorAction SilentlyContinue  # clear the 0-byte leftover
    exit 0
}

$msg = Get-Content $pendingFile -Raw
if (-not $msg) {
    Remove-Item $pendingFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# One-shot: clear before emitting so a hook error doesn't replay forever.
Remove-Item $pendingFile -Force -ErrorAction SilentlyContinue

Write-HookJson @{ additional_context = $msg }
exit 0
