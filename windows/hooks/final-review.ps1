# final-review.ps1 - stop hook (Cursor).
#
# ONE comprehensive end-of-implementation review across six axes:
# intent, correctness, reliability, coverage, anti-slop, and wiring completeness. When the agent finishes an
# implementation that touched files, Cursor auto-submits this hook's
# `followup_message` as the next user turn, so the model re-audits everything it
# changed this session and FIXES what fails - the model-as-auditor pattern over
# the whole implementation (the per-edit afterFileEdit hooks catch each edit;
# this catches the finished whole).
#
# Bounded so it can't loop forever:
#   - a per-conversation reviewed-flag: the stop AFTER the review pass clears
#     it and ends the loop (one review per implementation). NOTE: we do NOT
#     gate on stdin's loop_count - docs define it as cumulative follow-ups
#     "for this conversation", so a loop_count>=1 guard would suppress every
#     review after the first implementation in a long conversation,
#   - loop_limit in hooks.json caps runaway follow-ups harness-side,
#   - only if a file was actually edited this loop (the session-edits marker
#     written by self-review-trigger.ps1). Pure Q&A turns get nothing.
# Plus: only on status == 'completed' (not aborted/errored).
#
# Always emits valid JSON ({} = no follow-up). The review prompt lives in
# final-review.md next to this script (embedded fallback if missing).
# Disable: HOOKS_ENFORCE=0 or FINAL_REVIEW_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

function Emit-None { '{}'; exit 0 }

if ($env:HOOKS_ENFORCE -eq '0' -or $env:FINAL_REVIEW_ENFORCE -eq '0') { Emit-None }

$obj = Read-HookStdinJson
if (-not $obj) { Emit-None }

$status = ''
if ($obj.PSObject.Properties['status']) { $status = [string]$obj.status }
$cid = Get-SafeConversationId $obj

$pendingDir = Get-HooksPendingDir
$marker = Join-Path $pendingDir "session-edits-$cid.txt"
$flag   = Join-Path $pendingDir "reviewed-$cid.flag"

# Sweep state from sessions that died before their stop hook ran. Cheap (one
# directory listing on an event that fires once per agent loop).
Get-ChildItem $pendingDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# One-shot brake: the previous stop for this conversation emitted the review.
# Clear the flag (and whatever the review pass itself edited) and end the loop.
if (Test-Path $flag) {
    Remove-Item $flag, $marker -Force -ErrorAction SilentlyContinue
    Emit-None
}

# Fold completed subagents' edit markers into this conversation's marker so
# the review covers delegated work (subagent edits fire afterFileEdit under
# the SUBAGENT's conversation_id; postToolUse never fires for the Task tool,
# so this stop-time fold is the terminal backstop after the per-tool fold in
# post-tool-use.ps1).
Merge-SubagentEditMarkers $obj $cid | Out-Null

# Review only a clean completion; otherwise just clear the marker and stop.
if ($status -and $status -ne 'completed') {
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Emit-None
}
# No edits this loop -> nothing to review.
if (-not (Test-Path $marker)) { Emit-None }
$edited = @(Get-Content $marker -ErrorAction SilentlyContinue |
    Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
Remove-Item $marker -Force -ErrorAction SilentlyContinue
if ($edited.Count -eq 0) { Emit-None }

# Compose the follow-up review prompt (md preferred, embedded fallback).
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
$body = ''
if (Test-Path $promptFile) { $body = Get-Content -Raw $promptFile }
if (-not $body) {
    $body = @'
FINAL REVIEW - audit everything you changed this session and FIX what fails
(do NOT revert the behaviour the user asked for):
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present;
     no tautological tests.
  4. Anti-slop - read ~/.agents/hooks/anti-slop.md and apply all 13 items to
     the session diff. If ~/.cursor/skills/anti-slop/scripts/scan_slop.py exists,
     run `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all` first.
     Consolidate clones; drop premature abstraction, unneeded deps, operational
     slop (retries, await-in-loop, log spam), unjustified files.
  5. Wiring completeness - for every user-visible behavior you added/changed
     (button, submit, API call, route, state transition), trace its execution
     path to a REAL EFFECT (persist, mutate, call, render). A dead end is slop:
     handleSubmit that does not persist, an endpoint no caller invokes, a store
     never consumed, a stub/TODO/console.log standing in for the effect. Wire it
     now or remove the dead half; mark later-stubs with TODO(wire):.
Fix now, re-run the scan + tests, then stop. If an axis is clean, say so in one line.
'@
}
$body = Expand-AgentPaths $body

$resolved = @($edited | ForEach-Object { Resolve-AgentPath $_ })
$fileList = ($resolved | Select-Object -First 30) -join "`n  "

# Tier 0: extract the last user <user_query> from the transcript so the model
# can trace every diff hunk back to a concrete request. Anything untraceable is
# a hallucinated requirement. Empty when there is no transcript or no user_query
# (sandboxed verify runs, fresh installs) — the axis is then a no-op.
$userQuery = Get-LastUserQuery $obj
$intentBlock = ''
if ($userQuery) {
    $intentBlock = "ORIGINAL REQUEST (your last user message, for intent trace):`n---`n$userQuery`n---`n`n"
}

# Tier 5: cross-file change-surface metric. The per-file afterFileEdit audits
# miss the 50-file rename case; this seeds the whole-session footprint so the
# model can judge whether the change surface is proportional to the request.
$uniqueFiles = @($edited | Select-Object -Unique).Count
$surfaceBlock = "Session footprint: $uniqueFiles file(s) touched. If a simple request produced >5 files or >200 lines, justify each file's inclusion or trim.`n`n"

$msg = "FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop.`n`n${surfaceBlock}${intentBlock}Files you changed this session:`n  $fileList`n`n$body"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-HookJson @{ followup_message = $msg }
exit 0
