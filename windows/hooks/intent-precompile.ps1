# intent-precompile.ps1 - beforeSubmitPrompt: seed/update .scope.json from the prompt.
#
# THE fix for ".scope.json isn't updating": fires right after the user hits
# send, BEFORE the agent's first token, with the prompt in the payload directly.
# Writes the prompt as .scope.json's `intent` field. If .scope.json already
# exists, PRESERVES files[] and acceptance (cross-prompt continuity — the
# blast radius accumulates across turns). If it doesn't exist, creates it.
#
# This is the hook that makes .scope.json track the conversation without
# relying on the agent to write it. The agent refines intent/acceptance as
# its first action; the hook just ensures the contract EXISTS and reflects
# the current prompt. scope-refresh (afterFileEdit) then keeps files[] in
# sync as edits happen.
#
# Skips hook-generated auto-submits (FINAL REVIEW / SCOPE REMINDER / etc.) —
# those are review boilerplate, not user prompts. Never blocks; writes files
# as a side effect and exits 0. No repo root → silent (no ghost files in $HOME).
# Disable: HOOKS_ENFORCE=0 or INTENT_PRECOMPILE_ENFORCE=0.

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:INTENT_PRECOMPILE_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

$prompt = ''
if ($obj.PSObject.Properties['prompt']) { $prompt = [string]$obj.prompt }
$prompt = $prompt.Trim()
if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

# Skip hook-generated auto-submits (review followups the harness resubmits).
if ($prompt -match '(?m)^\s*(FINAL REVIEW \(end of implementation\)|SUBAGENT FINAL REVIEW|SELF-REVIEW|INTENT ANCHOR|INTENT REFINEMENT REQUIRED|SCOPE REMINDER)') { exit 0 }

$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

$scopePath = Join-Path $root '.scope.json'
$defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.'

# Read existing contract to preserve files[] and acceptance.
$existing = $null
if (Test-Path -LiteralPath $scopePath) {
    try { $existing = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json } catch { }
}

try {
    if ($existing) {
        # Update intent to the new prompt; preserve files[] and acceptance.
        $ordered = [ordered]@{}
        foreach ($p in $existing.PSObject.Properties) { $ordered[$p.Name] = $p.Value }
        $ordered['intent'] = $prompt
    } else {
        $ordered = [ordered]@{
            intent     = $prompt
            files      = @()
            acceptance = $defaultAcceptance
        }
    }
    $json = $ordered | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($scopePath, $json, [System.Text.UTF8Encoding]::new($false))
} catch { }

exit 0
