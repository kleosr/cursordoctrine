# final-review.ps1 - stop hook (Cursor).
#
# ONE comprehensive end-of-implementation review across four axes:
# correctness, reliability, coverage, and anti-slop. When the agent finishes an
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
  4. Anti-slop - if ~/.cursor/skills/anti-slop/scripts/scan_slop.py exists, run
     `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all`; otherwise
     apply ~/.agents/hooks/anti-slop.md to the session diff (a missing scanner
     is not a failure). Consolidate clones/duplicates to one source of truth;
     drop premature abstraction, unneeded deps, redundant comments, dead helpers.
Fix now, re-run the scan + tests, then stop. If an axis is clean, say so in one line.
'@
}

$fileList = ($edited | Select-Object -First 30) -join "`n  "
$msg = "FINAL REVIEW (end of implementation) - correctness, reliability, coverage, anti-slop.`n`nFiles you changed this session:`n  $fileList`n`n$body"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
try { New-Item -ItemType File -Path $flag -Force | Out-Null } catch { }

Write-HookJson @{ followup_message = $msg }
exit 0
