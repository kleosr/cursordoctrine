# post-tool-use.ps1 - postToolUse for Cursor.
#
# Two responsibilities, both message-bus work, keyed by conversation_id so
# concurrent sessions never receive each other's prompts:
#
#   1. Fold completed subagents' session-edits markers into this
#      conversation's marker (postToolUse does NOT fire for the Task tool -
#      verified - so this per-tool-boundary fold is how delegated edits reach
#      the parent's stop-hook final review). When a fold happens, prime the
#      parent to audit the subagent's diff now.
#   2. Drain this conversation's stashed self-review / advisory messages into
#      Cursor's additional_context channel. One-shot delivery.
#
# We do not parse, score, or filter. We do not run any audit. We do not
# block. The model that already produced the edit will, on its next
# turn, do the self-review.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

$obj = Read-HookStdinJson
$cid = Get-SafeConversationId $obj

$foldNote = ''
if (Merge-SubagentEditMarkers $obj $cid) {
    $foldNote = "SUBAGENT WORK DETECTED - a subagent of this conversation edited files (its edits fired hooks in ITS context, not yours). YOU are the auditor of its work: audit its diff (git status / git diff on the files it touched) against ~/.agents/hooks/self-review.md. Fix real bugs; stay silent otherwise. Its files are folded into this conversation's end-of-implementation review."
}

$pendingFile = Join-Path (Get-HooksPendingDir) "feedback-$cid.txt"

$msg = ''
if (Test-Path $pendingFile) {
    if ((Get-Item $pendingFile).Length -gt 0) {
        $msg = Get-Content $pendingFile -Raw
    }
    # One-shot: clear before emitting so a hook error doesn't replay forever.
    Remove-Item $pendingFile -Force -ErrorAction SilentlyContinue
}

if ($foldNote) {
    if ($msg) { $msg = "$foldNote`n`n---`n`n$msg" } else { $msg = $foldNote }
}
if (-not $msg) { exit 0 }

Write-HookJson @{ additional_context = $msg }
exit 0
