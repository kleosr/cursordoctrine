# subagent-stop-review.ps1 - subagentStop for Cursor.
#
# Counterpart of final-review.ps1 for delegated work. afterFileEdit DOES fire
# inside subagents (verified: a poteto subagent run left ~58 entries in
# session-edits-<subagent-cid>.txt), but subagents get no `stop` event, so
# that marker is never drained and the four-axis review never fires for
# delegated implementations. This hook closes the loop: when a subagent
# finishes and ITS conversation has a session-edits marker, return ONE
# followup_message so the subagent audits its own implementation before the
# result goes back to the parent.
#
# Same bounding pattern as final-review.ps1:
#   - marker-gated: no edits in the subagent run -> no review, no noise,
#   - reviewed-<cid>.flag one-shot brake: the stop AFTER the review pass
#     clears flag + marker and ends the loop (one review per implementation;
#     resumed subagents with a second implementation get a second review),
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only on status == 'completed' when a status field is present.
#
# If subagentStop's stdin carries a conversation_id that doesn't match the
# id afterFileEdit used, the marker lookup misses and this emits {} - the
# marker fold in post-tool-use.ps1 / final-review.ps1 still routes the
# subagent's edits into the parent's stop review as the backstop.
#
# Always emits valid JSON ({} = no follow-up). Review body reuses
# final-review.md (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or SUBAGENT_REVIEW_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

function Emit-None { '{}'; exit 0 }

if ($env:HOOKS_ENFORCE -eq '0' -or $env:SUBAGENT_REVIEW_ENFORCE -eq '0') { Emit-None }

$obj = Read-HookStdinJson
if (-not $obj) { Emit-None }

$status = ''
if ($obj.PSObject.Properties['status']) { $status = [string]$obj.status }
$cid = Get-SafeConversationId $obj

$pendingDir = Get-HooksPendingDir
$marker = Join-Path $pendingDir "session-edits-$cid.txt"
$flag   = Join-Path $pendingDir "reviewed-$cid.flag"

# One-shot brake: the previous subagentStop for this id emitted the review.
if (Test-Path $flag) {
    Remove-Item $flag, $marker -Force -ErrorAction SilentlyContinue
    Emit-None
}

# Review only a clean completion; otherwise clear the marker and stop.
if ($status -and $status -ne 'completed') {
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Emit-None
}

# No edits this run -> nothing to review.
if (-not (Test-Path $marker)) { Emit-None }
$edited = @(Get-Content $marker -ErrorAction SilentlyContinue |
    Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
Remove-Item $marker -Force -ErrorAction SilentlyContinue
if ($edited.Count -eq 0) { Emit-None }

$body = ''
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
if (Test-Path $promptFile) { $body = Get-Content -Raw $promptFile }
if (-not $body) {
    $body = @'
Audit everything you changed in this run and FIX what fails (do NOT revert the
behaviour the task asked for):
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled, no swallowed errors, resources released.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present.
  4. Anti-slop - no duplicate helpers, premature abstraction, unneeded deps,
     redundant comments, dead code.
If an axis is clean, say so in one line. Then stop.
'@
}

$fileList = ($edited | Select-Object -First 30) -join "`n  "
$msg = "SUBAGENT FINAL REVIEW - you just finished delegated implementation work. Before your result returns to the parent agent, audit it.`n`nFiles you changed this run:`n  $fileList`n`n$body"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-HookJson @{ followup_message = $msg }
exit 0
