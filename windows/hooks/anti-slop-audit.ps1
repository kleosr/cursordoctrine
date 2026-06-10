# anti-slop-audit.ps1 - afterFileEdit "AI slop" advisory (Cursor).
#
# Companion to minimal-edit-audit.ps1. That hook guards ONE slop axis -
# over-editing (diff size / token-Levenshtein / added complexity). This hook
# guards the rest of the taxonomy: the parts static analysis can cheaply and
# precisely flag, plus a self-review checklist for the parts it cannot.
#
#   Statically flagged (high-precision, deliberately low false-positive):
#     * new dependency added to a manifest (package.json / requirements*.txt /
#       pyproject.toml / Pipfile / go.mod / Cargo.toml / Gemfile / composer.json
#       / pom.xml / build.gradle / *.csproj / packages.config)
#     * premature abstraction: a new *Factory / *Repository / *Mediator /
#       *Strategy / *Singleton / *Facade / *Builder / *Visitor / *Decorator
#       class, or CQRS / Event-Sourcing / DDD vocabulary
#     * redundant comments that merely restate the next line of code
#
#   Deferred to the model (semantic - no regex can judge these without drowning
#   the user in false positives): edge cases, duplicated logic, ignored
#   conventions, accidental complexity, superficial tests, cargo-cult copying,
#   architectural violations. The injected anti-slop.md checklist primes the
#   model to audit its own just-made edit against them and fix/revert the slop.
#
# Fires when a static signal trips OR the edit added a substantial block of new
# source (>= ANTI_SLOP_CHECKLIST_LINES, default 40). Otherwise silent, so it
# stays proportional to risk and does not spam trivial edits.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0.
# afterFileEdit output is not consumed, so we APPEND the advisory to the shared
# pending file and post-tool-use.ps1 delivers it as additional_context next
# turn. Native git only (no bash). Self-contained.
#
# Disable: HOOKS_ENFORCE=0  or  ANTI_SLOP_ENFORCE=0
# Tune:    ANTI_SLOP_CHECKLIST_LINES (40)

$ErrorActionPreference = 'SilentlyContinue'
. "$PSScriptRoot\hook-common.ps1"

if ($env:HOOKS_ENFORCE -eq '0' -or $env:ANTI_SLOP_ENFORCE -eq '0') { exit 0 }

$obj = Read-HookStdinJson
if (-not $obj) { exit 0 }

# audit root: project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
$root = ''
$cands = @()
if ($obj.PSObject.Properties['cwd'] -and $obj.cwd) { $cands += [string]$obj.cwd }
if ($obj.PSObject.Properties['workspace_roots']) { foreach ($w in $obj.workspace_roots) { $cands += [string]$w } }
foreach ($c in $cands) { $f = ConvertTo-FwdPath $c; if ($f -and (Test-Path -LiteralPath $f)) { $root = $f.TrimEnd('/'); break } }
if (-not $root) { $root = (& { if ($env:CURSOR_PROJECT_DIR) { $env:CURSOR_PROJECT_DIR } else { $HOME } }).Replace('\', '/').TrimEnd('/') }

# edited file -> repo-relative forward-slash path
$fp = ''
foreach ($k in 'file_path', 'path', 'filename', 'absolute_path', 'abs_path') {
    if ($obj.PSObject.Properties[$k] -and $obj.$k) { $fp = [string]$obj.$k; break }
}
if (-not $fp) { exit 0 }
$rel = ConvertTo-FwdPath $fp
if ($rel.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($root.Length + 1) }
if (Test-IsCursorConfigPath $fp) { exit 0 }
if (Test-IsCursorConfigPath $rel) { exit 0 }

# git repo?
& git -C $root rev-parse --git-dir 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

# --- collect ADDED lines for this file (working tree vs HEAD) -------------
$added = New-Object System.Collections.Generic.List[string]
foreach ($l in (& git -C $root diff HEAD -- $rel 2>$null)) {
    if ($l.Length -gt 0 -and $l[0] -eq '+' -and -not $l.StartsWith('+++')) {
        $added.Add($l.Substring(1))
    }
}
if ($added.Count -eq 0) {
    # untracked / brand-new file: git diff HEAD shows nothing -> whole file is "added"
    & git -C $root ls-files --error-unmatch -- $rel 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $abs = "$root/$rel"
        if (Test-Path -LiteralPath $abs) {
            foreach ($l in (Get-Content -LiteralPath $abs)) { $added.Add([string]$l) }
        }
    }
}
if ($added.Count -eq 0) { exit 0 }
if ($added.Count -gt 1500) { $added = $added.GetRange(0, 1500) }

$base = ($rel -split '/')[-1]

# --- signal 1: new dependency in a manifest ------------------------------
$depAdded = $false
$isManifest = ($base -match '^(package\.json|requirements[\w.\-]*\.txt|pyproject\.toml|Pipfile|go\.mod|Cargo\.toml|Gemfile|composer\.json|pom\.xml|build\.gradle(\.kts)?|packages\.config)$') -or ($base -match '\.csproj$')
if ($isManifest) {
    # Strip metadata key/value pairs that match the dependency value-shape but
    # are not dependencies ("version": "1.0.1" flagged DEPENDENCY on every
    # version bump otherwise). Anchored to {,/line-start so XML attributes
    # (csproj PackageReference Version="...") are NOT stripped and still flag.
    $metaStrip = '(?:^|[\{,])\s*[''"]?(version|name|description|license|author|main|module|types|typings|type|engines|packageManager|private|sideEffects|homepage|repository|keywords|edition|rust-version|python-requires|requires-python)[''"]?\s*[:=]\s*([''"][^''"]*[''"]|[^,}\s]+)'
    foreach ($a in $added) {
        $clean = $a -replace $metaStrip, ''
        if ($clean -match '(?:^|[\{,])\s*[''"]?[A-Za-z@][\w@\-./\[\]]*[''"]?\s*([:=]\s*[''"]?[\^~>=<*v]?\d|[><=~!]=\s*\d|@\s*\^?\d)') { $depAdded = $true; break }
    }
}

# --- signal 2: premature abstraction (named patterns + DDD vocabulary) ----
$patterns = New-Object System.Collections.Generic.List[string]
$nameRe = '\b(?:class|interface|struct|trait|protocol)\s+([A-Z][A-Za-z0-9_]*(?:Factory|Repository|Mediator|Strategy|Singleton|Facade|Builder|Visitor|Decorator))\b'
$kwRe   = '\b(CQRS|Event[\s\-]?Sourc(?:e|ing)|Domain[\s\-]?Driven|Aggregate\s?Root|Bounded\s?Context)\b'
foreach ($a in $added) {
    if ($a -match $nameRe -and -not $patterns.Contains($Matches[1])) { $patterns.Add($Matches[1]) }
    elseif ($a -match $kwRe -and -not $patterns.Contains($Matches[1])) { $patterns.Add($Matches[1]) }
    if ($patterns.Count -ge 5) { break }
}

# --- signal 3: redundant comments that restate the code -------------------
$redundant = New-Object System.Collections.Generic.List[string]
$cmtRe = '^\s*(?://|#|/\*+)\s*(increment|decrement|loop (?:over|through)|iterate|returns?( the)?( result| value)?\s*$|set\s+\w+\s+to\b|getter\b|setter\b|constructor\b|initiali[sz]e\b|instantiate\b|create (?:a |an |the )|declare\b|define\b|assign\b|end (?:of|for)\b|begin\b|start (?:of|the))'
foreach ($a in $added) {
    if ($a -match $cmtRe) {
        # Word guard: a real restate-the-code comment is short; long comments are
        # genuine explanations (false positives), so cap the body at 6 words.
        $body = (($a -replace '^\s*(?://+|#+|/\*+|\*+)\s*', '') -replace '\*/\s*$', '').Trim()
        $wc = @($body -split '\s+' | Where-Object { $_ -ne '' }).Count
        if ($wc -le 6) {
            $t = $a.Trim()
            if ($t.Length -gt 80) { $t = $t.Substring(0, 77) + '...' }
            if (-not $redundant.Contains($t)) { $redundant.Add($t) }
        }
    }
    if ($redundant.Count -ge 4) { break }
}

# --- decide whether to fire ----------------------------------------------
$srcRe = '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|kts|cs|cpp|cc|cxx|c|h|hpp|rb|php|swift|scala|m|mm|sh|ps1|lua|dart|ex|exs|vue|svelte)$'
$addedCode = 0
foreach ($a in $added) { if ($a.Trim() -ne '') { $addedCode++ } }
$checklistLines = if ($env:ANTI_SLOP_CHECKLIST_LINES) { [int]$env:ANTI_SLOP_CHECKLIST_LINES } else { 40 }
$substantial = ($rel -match $srcRe) -and ($addedCode -ge $checklistLines)

$flags = New-Object System.Collections.Generic.List[string]
if ($depAdded)              { $flags.Add("- DEPENDENCY: " + $base + " gained a dependency - is it necessary, or do the stdlib / existing deps already cover it?") }
if ($patterns.Count -gt 0)  { $flags.Add("- PREMATURE ABSTRACTION: " + ($patterns -join ', ') + " - is there a real, present problem (2-3+ call sites that exist today) that needs it? If it is speculative, delete it and write the direct code.") }
if ($redundant.Count -gt 0) { $flags.Add("- REDUNDANT COMMENTS: " + ($redundant -join ' | ') + " - delete comments that restate the code; keep only WHY.") }

if ($flags.Count -eq 0 -and -not $substantial) { exit 0 }

# --- load the slop checklist (md preferred, embedded fallback) ------------
$checklistFile = Join-Path $HOME '.agents\hooks\anti-slop.md'
$checklist = ''
if (Test-Path -LiteralPath $checklistFile) { $checklist = Get-Content -Raw -LiteralPath $checklistFile }
if (-not $checklist) {
    $checklist = @'
ANTI-SLOP SELF-REVIEW - audit the edit you just made and FIX (do not explain) any slop:
  1. Edge cases beyond the happy path (null / empty / zero / boundary / error).
  2. Duplicated logic that already exists in this repo - call it, do not re-implement.
  3. Conventions - match the file's existing style / naming / structure / error-handling.
  4. Unnecessary dependencies - remove libs the stdlib or an existing dep covers.
  5. Premature abstraction - no Factory/Repository/Mediator/CQRS/DDD without 2-3 real call sites today.
  6. Accidental complexity - flatten indirection a junior cannot read in 30s.
  7. Tests assert real behaviour and edge cases, not just "it runs".
  8. Cargo cult - delete any construct whose reason you cannot state.
  9. Architecture - respect the project's layering and boundaries.
 10. Redundant comments restating code - delete; keep only WHY.
'@
}

$flagBlock = if ($flags.Count -gt 0) { "Static signals on this edit:`n" + ($flags -join "`n") + "`n`n" } else { '' }

# Concatenate (do NOT interpolate $checklist - its content must stay literal).
$header = "Anti-slop audit - $rel`n`n"
$footer = "`n`n(Advisory; the bug pass is the self-review trigger. Disable: ANTI_SLOP_ENFORCE=0)"
$msg = $header + $flagBlock + $checklist + $footer

# --- append to the shared pending file ------------------------------------
$cid = Get-SafeConversationId $obj
$pending = Join-Path (Get-HooksPendingDir) "feedback-$cid.txt"
try {
    New-Item -ItemType Directory -Path (Split-Path $pending) -Force | Out-Null
    $prefix = ''
    if ((Test-Path $pending) -and ((Get-Item $pending).Length -gt 0)) { $prefix = "`n`n---`n`n" }
    Add-Content -Path $pending -Value ($prefix + $msg) -NoNewline
} catch { }

exit 0
