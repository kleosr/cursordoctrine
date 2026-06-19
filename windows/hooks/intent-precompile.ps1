# intent-precompile.ps1 - beforeSubmitPrompt "contract first" writer (Cursor).
#
# THE FIX for "el .scope.json se crea casi al final": creation used to live on
# postToolUse (intent-anchor), which fires only AFTER the agent's first tool and
# depends on the transcript becoming readable to detect the prompt. Until then the
# PREVIOUS prompt's intent persisted and the agent worked under it - the scope
# only flipped to the right intent late in the turn.
#
# beforeSubmitPrompt fires "right after the user hits send, before the backend
# request" - the earliest possible moment, BEFORE the agent's first token - and
# its payload carries the user's `prompt` DIRECTLY (no <user_query> extraction, no
# transcript dependency, no hook-followup contamination). So this hook writes
# .scope.json with the real intent up front, making the contract the FIRST artifact
# of the turn, which the agent then governs by.
#
# It does TWO things, both deterministic:
#   1. STASH the verbatim prompt to current-prompt-<cid>.txt. intent-anchor prefers
#      this over transcript parsing, so both hooks hash the SAME text and never
#      fight over _intent_hash.
#   2. WRITE / REGENERATE .scope.json from the prompt when it is new (hash differs)
#      or missing. Same prompt as on disk -> leave it (preserve the agent's refined
#      intent / acceptance / files within the turn). acceptance is seeded with a
#      real default (Get-DefaultAcceptance), never a bare <TODO>.
#
# Hook-generated submits (final-review / subagent-review followups that Cursor
# auto-submits) are SKIPPED: their prompt is review boilerplate, not the user's
# request - stashing or regenerating from them is the contamination loop.
#
# Never blocks submission (no `continue:false`); writes files as a side effect and
# exits 0. Disable: HOOKS_ENFORCE=0 or INTENT_ANCHOR_ENFORCE=0 (shares the
# intent-anchor kill switch - they are one subsystem).

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:INTENT_ANCHOR_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

# --- the prompt (direct from payload - the whole point of this event) --------
$prompt = ''
if ($obj.PSObject.Properties['prompt']) { $prompt = [string]$obj.prompt }
$prompt = $prompt.Trim()
if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

# Auto-submitted hook followups (FINAL REVIEW / SUBAGENT / SELF-REVIEW / INTENT
# ANCHOR) are not the user's request. Leave the real contract intact.
if (Test-IsHookGeneratedQuery $prompt) { exit 0 }

$prompt = Redact-SecretsFromIntent $prompt

$cid = Get-SafeConversationId $obj
$pendingDir = Get-HooksPendingDir

# --- repo root (workspace_roots / cwd; NO $HOME fallback - no ghost files) ----
$root = ''
$cands = @()
if ($obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
if ($obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
foreach ($c in $cands) { $f = ConvertTo-FwdPath $c; if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break } }
if (-not $root -and $env:CURSOR_PROJECT_DIR) {
    $cpd = $env:CURSOR_PROJECT_DIR.Replace('\', '/').TrimEnd('/')
    if (Test-Path -LiteralPath $cpd) { $root = $cpd }
}
if (-not $root) { exit 0 }

# --- stash the prompt so intent-anchor reads the same ground-truth text -------
try {
    New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Get-CurrentPromptPath $cid), $prompt, [System.Text.UTF8Encoding]::new($false))
} catch { }

# --- write / regenerate .scope.json (hash-gated) ------------------------------
$currentHash = Get-Sha256Hex $prompt
$scopePath = Join-Path $root '.scope.json'
$onDiskHash = ''
if (Test-Path -LiteralPath $scopePath) {
    try {
        $sj = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        if ($sj.PSObject.Properties['_intent_hash']) { $onDiskHash = [string]$sj._intent_hash }
    } catch { $onDiskHash = '' }   # malformed -> regenerate
}

# Same prompt already locked (by a prior fire this turn, or by the agent who may
# have refined intent/acceptance/files) -> leave it. Only (re)write on a NEW or
# missing/garbage contract.
if ($onDiskHash -eq $currentHash) { exit 0 }

try {
    $scaffold = [ordered]@{
        intent        = $prompt
        files         = @()
        acceptance    = (Get-DefaultAcceptance)
        allow_growth  = $false
        trace         = [ordered]@{ query = $prompt; ts = (Get-Date).ToString('o') }
        _intent_hash  = $currentHash
        _generated_by = 'intent-precompile hook (beforeSubmitPrompt)'
    }
    $json = $scaffold | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
