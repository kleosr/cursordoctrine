# final-review.ps1 - stop hook (Cursor).
#
# ONE comprehensive end-of-implementation review across seven axes:
# intent, correctness, reliability, coverage, anti-slop, wiring completeness,
# and mechanics & stack integrity. When the agent finishes an
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
$intentLatch = Join-Path $pendingDir "intent-injected-$cid.flag"

# Sweep state from sessions that died before their stop hook ran. Cheap (one
# directory listing on an event that fires once per agent loop).
Get-ChildItem $pendingDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Unconditionally clear the intent-anchor per-turn latch so the next turn
# re-fires. Every stop is a turn boundary; clearing here (not only inside the
# reviewed-flag block below) guarantees it re-fires on the first tool of the
# NEXT turn and can never get stranded silenced mid-session.
# last-query-<cid>.hash is NOT cleared here - it persists turn-to-turn so
# intent-anchor can detect prompt changes; the 7-day sweep above reaps it.
Remove-Item $intentLatch -Force -ErrorAction SilentlyContinue

# --- INTENT ENFORCEMENT GATE (Tier -1, the fix for "intent stays verbatim") ---
# intent-anchor.ps1 already DEMANDS the Step 0 restatement via additional_context,
# but additional_context is advisory noise the agent routinely buries -> intent
# stays byte-identical to trace.query for the whole turn. The ONLY non-advisory
# lever in this harness is a stop followup_message: Cursor resubmits it as a REAL
# user turn (max salience), not ignorable context. So if the agent stops with
# intent still verbatim, force ONE sharp followup whose sole instruction is the
# string-replace on .scope.json. Bounded: intent-gate-fired-<cid>.hash records the
# _intent_hash it fired on -> fires AT MOST ONCE per prompt (if ignored, give up
# gracefully instead of starving the real review of loop_limit turns). Resets
# automatically when the prompt changes (hash differs). Precondition-first: a
# final review against a verbatim intent is auditing the wrong contract.
$gateRoot = Resolve-ProjectRoot $obj
if ($gateRoot) {
    $gateScope = Join-Path $gateRoot '.scope.json'
    if (Test-Path -LiteralPath $gateScope) {
        $gateSj = $null
        try { $gateSj = Get-Content -LiteralPath $gateScope -Raw | ConvertFrom-Json } catch { $gateSj = $null }
        if ($gateSj -and $gateSj.PSObject.Properties['intent'] -and $gateSj.trace) {
            $gIntent = [string]$gateSj.intent
            $gTrace  = ''
            if ($gateSj.trace.PSObject.Properties['query']) { $gTrace = [string]$gateSj.trace.query }
            $gHash = ''
            if ($gateSj.PSObject.Properties['_intent_hash']) { $gHash = [string]$gateSj._intent_hash }
            $gVerbatim = (-not [string]::IsNullOrWhiteSpace($gIntent)) `
                -and (-not [string]::IsNullOrWhiteSpace($gTrace)) `
                -and ($gIntent.Trim() -ieq $gTrace.Trim())
            if ($gVerbatim -and $gHash) {
                $gateFiredFile = Join-Path $pendingDir "intent-gate-fired-$cid.hash"
                $gFiredHash = ''
                if (Test-Path $gateFiredFile) { $gFiredHash = (Get-Content $gateFiredFile -Raw -ErrorAction SilentlyContinue).Trim() }
                if ($gFiredHash -ne $gHash) {
                    try { Set-Content -Path $gateFiredFile -Value $gHash -NoNewline -ErrorAction SilentlyContinue } catch { }
                    $scopeFwd = ConvertTo-FwdPath $gateScope
                    $gateMsg = @"
INTENT REFINEMENT REQUIRED (precondition before any review or further work).

You stopped, but .scope.json's 'intent' field is still your VERBATIM request
(byte-identical to 'trace.query') - you never did your Step 0 restatement, so
you have not confirmed you understood the request. Do EXACTLY this one edit and
nothing else:

  1. Open $scopeFwd
  2. Replace ONLY the value of the 'intent' field with ONE operational sentence
     in YOUR OWN words: the request restated - grammar fixed, pronouns resolved,
     implicit constraints made explicit, meaning preserved. Not 'improve X' -
     the concrete verb (what to make return / change / happen).
  3. Do NOT touch 'trace.query', '_intent_hash', '_generated_by', 'files', or
     'acceptance'. Do NOT rewrite the whole file - one targeted string-replace
     on the 'intent' value only.

'intent' and 'trace.query' must say the SAME thing in DIFFERENT words. Make this
single edit, then stop.
"@
                    Write-HookJson @{ followup_message = $gateMsg }
                    exit 0
                }
            }
        }
    }
}

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
  0. Intent trace - tie every diff hunk back to the ORIGINAL REQUEST above.
     Anything untraceable is a hallucinated requirement: revert it. Runs FIRST.
  1. Correctness - logic, edge cases (null/empty/zero/boundary), language traps, security.
  2. Reliability - error paths handled (no empty catch), timeouts/retries, resources
     released on every path, no races, input validated at the boundary.
  3. Coverage - behaviour-bearing changes have real tests; RUN the suite if present;
     no tautological tests.
  4. Anti-slop - if the anti-slop scanner exists, run `python <scanner> --all` first;
     then read ~/.agents/hooks/anti-slop.md (the single source of truth) and apply all
     13 items to the session diff. Consolidate clones; drop premature abstraction,
     unneeded deps, operational slop, unjustified files. Do NOT re-list the items here.
  5. Wiring completeness - for every user-visible behavior you added/changed
     (button, submit, API call, route, state transition), trace its execution
     path to a REAL EFFECT (persist, mutate, call, render). A dead end is slop:
     handleSubmit that does not persist, an endpoint no caller invokes, a store
     never consumed, a stub/TODO/console.log standing in for the effect. Wire it
     now or remove the dead half; mark later-stubs with TODO(wire):.
Fix now, re-run the scan + tests, then stop. If an axis is clean, say so in one line.
'@
}
# Expand ~ in the body AND in the fallback above, so the model gets literal
# absolute paths it can paste into pwsh on Windows (where ~ does NOT expand).
# Same treatment applied to the scanner path so the anti-slop Step A command runs.
$body = Expand-AgentPaths $body

# Regla R1 (re-entry): if this review pass is a re-audit after a failed gate or
# axis, suppress History Propagation - the model must NOT build on its own prior
# wrong diff. Reset its prior to the Anchor Set, not to its previous attempt.
$reentryLine = "`n`nRE-ENTRY RULE (Regla R1): if a gate or axis failed, forget the approach that produced it. Re-read your ORIGINAL REQUEST above and your Anchor Set (.scope.json, maintained by the intent-anchor hook). Fix ONLY what is failing. Do not refactor in this pass - that is History Propagation, the exact failure mode the Anchor Set exists to prevent.`n"

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

$msg = "FINAL REVIEW (end of implementation) - intent, correctness, reliability, coverage, anti-slop.`n`n${surfaceBlock}${intentBlock}Files you changed this session:`n  $fileList`n`n$body${reentryLine}"

# Arm the one-shot brake BEFORE emitting, so a crash after emit can't re-fire.
New-Item -ItemType File -Path $flag -Force -ErrorAction SilentlyContinue | Out-Null

Write-HookJson @{ followup_message = $msg }
exit 0
