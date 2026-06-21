# subagent-stop-review.ps1 - subagentStop for Cursor.
#
# Counterpart of final-review.ps1 for delegated work. afterFileEdit DOES fire
# inside subagents (verified: a subagent run left its edits in
# session-edits-<subagent-cid>.txt), but subagents get no `stop` event, so
# that marker is never drained and the seven-axis review never fires for
# delegated implementations. This hook closes the loop: when a subagent
# finishes and edited files, return ONE followup_message so the subagent
# audits its own implementation before the result goes back to the parent.
#
# NO matcher on subagentStop: fires for every subagent type, but a read-only
# subagent (explore/shell that never edits) has no marker and no
# modified_files, so it emits {} and stays silent. Editing-capable types
# (generalPurpose, Cursor's internal poteto/best-of-N/manual-edit, and any
# future type) are all covered without depending on undocumented type names.
#
# Edit detection is BELT-AND-SUSPENDERS (see the inline block): the
# per-cid marker (authoritative, drained on read) UNION the modified_files[]
# field Cursor puts in the subagentStop payload (cid-independent). The
# payload fallback covers the case where subagentStop surfaces the PARENT's
# conversation_id instead of the subagent's - the marker lookup would miss,
# but modified_files still names the files. If both are empty, nothing was
# edited -> silent.
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
# id afterFileEdit used, the marker lookup misses - but the modified_files[]
# payload fallback (below) + the marker fold in post-tool-use.ps1 /
# final-review.ps1 (which scans the subagents/ dir, cid-independent) still
# route the subagent's edits into review. Belt and suspenders.
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
$intentLatch = Join-Path $pendingDir "intent-injected-$cid.flag"

# Unconditionally clear the intent-anchor per-turn latch so the next subagent
# run re-fires. Clearing here (not only inside the reviewed-flag block below)
# can never strand it silenced. last-query-<cid>.hash is kept (cross-turn
# prompt-change detect).
Remove-Item $intentLatch -Force -ErrorAction SilentlyContinue

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

# Edits this run: AUTHORITATIVE marker (drained) + modified_files payload fallback.
# The marker is populated by self-review-trigger on each afterFileEdit inside the
# subagent. If subagentStop's conversation_id matches the one afterFileEdit used,
# the marker is here and is the most accurate ledger (the hook saw every edit).
# If the cids DON'T match (Cursor may surface the parent's cid in subagentStop),
# fall back to the modified_files[] array Cursor puts in the subagentStop payload
# itself - that signal is cid-independent. Either source alone is enough; union
# both so a delegated implementation is never silently skipped. No edits at all
# (read-only explore/shell subagents) -> {}.
$edited = @()
if (Test-Path $marker) {
    $edited = @(Get-Content $marker -ErrorAction SilentlyContinue |
        Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
    Remove-Item $marker -Force -ErrorAction SilentlyContinue   # drain (self-reviewed)
}
if ($obj.PSObject.Properties['modified_files'] -and $obj.modified_files) {
    foreach ($f in @($obj.modified_files)) {
        if ($f -is [string]) {
            $ft = $f.Trim()
            if ($ft -and ($edited -notcontains $ft)) { $edited += $ft }
        }
    }
}
if ($edited.Count -eq 0) { Emit-None }

$body = ''
$promptFile = Join-Path $HOME '.agents\hooks\final-review.md'
if (Test-Path $promptFile) { $body = Get-Content -Raw $promptFile }
if (-not $body) {
    $body = @'
Audit everything you changed in this run and FIX what fails (do NOT revert the
behaviour the task asked for). Seven axes, in order:
  0. Intent trace - tie every diff hunk back to your original task. Untraceable = hallucinated.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled, no swallowed errors, resources released.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present.
  4. Anti-slop - the header's ANTI-SLOP SCAN block is scoped to the files you
     changed (NOT --all): fix those hits on lines you added. If absent, run the
     scanner on <the files above> (never --all at review time). Then read
     ~/.agents/hooks/anti-slop.md (single source of truth) and apply all items.
  5. Wiring completeness - trace every added behavior to a REAL EFFECT (persist/mutate/call/render).
     A dead end (handleSubmit that doesn't persist, an endpoint no caller invokes) is slop.
If an axis is clean, say so in one line. Then stop.
'@
}
$body = Expand-AgentPaths $body

# Regla R1 (re-entry): same suppression as final-review.ps1. A subagent that
# failed an axis must not build on its own prior wrong diff - reset its prior
# to the Anchor Set, not to its previous attempt.
$reentryLine = "`n`nRE-ENTRY RULE (Regla R1): if an axis failed, forget the approach that produced it. Re-read your original task and your Anchor Set (.scope.json, if you wrote one). Fix ONLY what is failing. Do not refactor in this pass.`n"

$resolved = @($edited | ForEach-Object { Resolve-AgentPath $_ })
$fileList = ($resolved | Select-Object -First 30) -join "`n  "
# Session-scoped anti-slop scan over ONLY the files changed this run (NOT --all,
# which audits the whole pre-existing codebase - not actionable here).
$gateRoot = Resolve-ProjectRoot $obj
$slopBlock = Get-SessionSlopBlock -Edited $edited -Root $gateRoot
$msg = "SUBAGENT FINAL REVIEW - you just finished delegated implementation work. Before your result returns to the parent agent, audit it.`n`nFiles you changed this run:`n  $fileList`n`n${slopBlock}$body${reentryLine}"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-HookJson @{ followup_message = $msg }
exit 0
