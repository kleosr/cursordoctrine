# anti-slop-audit.ps1 - afterFileEdit "AI slop" advisory (Cursor).
#
# Guards the parts of the slop taxonomy static analysis can cheaply and
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
#     * operational slop (Tier 3): retry-without-backoff, await-in-loop,
#       telemetry spam (>= 6 log/print statements added in one edit)
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

# audit root: shared resolver (cwd -> workspace_roots -> CURSOR_PROJECT_DIR; NO
# $HOME fallback - no ghost files, no auditing the wrong root).
$root = Resolve-ProjectRoot $obj
if (-not $root) { exit 0 }

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

# --- signal 4: operational slop (Tier 3) ----------------------------------
# Retry-without-backoff: a retry loop or recursive retry without an obvious
# sleep/backoff/setTimeout nearby. The whole-file body is scanned so the
# backoff can sit above or below the retry; this is deliberately seed-grade
# (high precision), not a verdict.
$opsFlags = New-Object System.Collections.Generic.List[string]
$bodyHas = {
    param($pat)
    foreach ($a in $added) { if ($a -match $pat) { return $true } }
    return $false
}
$retryWord    = '\b(retry|retryCount|retries|maxRetries|attempt)\w*\b'
$backoffWord  = '\b(sleep|setTimeout|backoff|back_off|exponential|jitter|delay)\w*\b'
if (& $bodyHas $retryWord) {
    $noBackoff = $true
    foreach ($a in $added) { if ($a -match $backoffWord) { $noBackoff = $false; break } }
    if ($noBackoff) {
        $opsFlags.Add("- RETRY WITHOUT BACKOFF: a retry construct was added but no sleep/backoff/setTimeout is visible in this edit's added lines. Unbounded retries = retry storms + token/cost burn; add bounded backoff or confirm the runtime already throttles.")
    }
}

# `await` (or `await ctx.db`) inside a loop construct on its own line — N+1 in
# agent/edge code, not just SQL. We seed on the added-line co-occurrence of a
# loop keyword and an awaited call; the model judges whether it is genuinely a
# sequential-await loop (real slop) or a legit streaming pattern.
$loopWord = '\b(for|while|forEach|map|filter|reduce|flatMap|for\s+await|async\s+for)\b'
$awaitCall = '\bawait\s+(fetch|ctx\.db|ctx\.run|client\.|axios|prisma\.|supabase\.|db\.|repo\.)'
if (& $bodyHas $loopWord) {
    $awaitInLoop = $false
    foreach ($a in $added) { if ($a -match $awaitCall) { $awaitInLoop = $true; break } }
    if ($awaitInLoop) {
        $opsFlags.Add("- AWAIT IN LOOP: a loop construct and an awaited IO call both appear in this edit. Sequential awaits in a loop = N+1 / serial latency; confirm whether Promise.all / a batch call / a single query is the right primitive. (If this is genuinely a streaming pattern, ignore.)")
    }
}

# Telemetry spam seed: 6+ console.log / print / fmt.Print / std::cout::<< added
# in one file. Models paste debug prints liberally; six is well past intent.
$logRe = '\b(console\.(log|debug|info|warn|error)|print\(|fmt\.Print|std::cout|NSLog|System\.out\.println|println!|dbg!|console\.dir)\b'
$logCount = 0
foreach ($a in $added) { if ($a -match $logRe) { $logCount++ } }
if ($logCount -ge 6) {
    $opsFlags.Add("- TELEMETRY SPAM: $logCount log/print statements added in this one edit. Debug-level telemetry that nobody reads is slop; consolidate or remove (kept only if this is a real logging entrypoint).")
}

# --- signal 5: AI vibe-coding structural slop (Arrow / Masking / Boolean /
# Switch Bloat) - high-precision regex/heuristics, deterministic, language-agnostic
# where possible. Each rule flags a SPECIFIC pattern that the model does because
# it cannot combine conditions or design types; the rule's "Stop" forces the
# canonical fix (guard clauses, fail-fast, named types, dictionary dispatch).
$vibeFlags = New-Object System.Collections.Generic.List[string]

# (5a) ARROW CODE: 3+ levels of nested if/for/while/switch in the ADDED lines.
# Measure indent depth of control-flow keywords; 3+ distinct nesting levels in
# one block = arrow code. The model nests because it cannot combine conditions.
# Stop: guard clauses (early returns) - read top-to-bottom, no deep indent.
$controlKw = '(?i)^\s*(if|for|while|switch|try|else|elif|else\s+if)\b'
$nestHits   = 0
$maxNest    = 0
foreach ($a in $added) {
    if ($a -notmatch $controlKw) { continue }
    $spaces = ($a -replace '\S.*$', '').Length
    # Normalize: assume 2-space or tab indent. Floor to indent LEVELS.
    $indents = [int][math]::Floor($spaces / 2)
    if ($indents -ge 3) {                         # 3+ levels of nesting
        $nestHits++
        if ($indents -gt $maxNest) { $maxNest = $indents }
    }
}
if ($nestHits -ge 2) {
    $vibeFlags.Add("- ARROW CODE: $nestHits control-flow lines at >= 3 levels of nesting (max level: $maxNest). The model nests because it cannot combine conditions. Stop: GUARD CLAUSES (early returns). If a condition does not hold, return immediately; the body must read top-to-bottom without deep indent.")
}

# (5b) SYMPTOM MASKING: empty catch, catch-and-swallow, or value-nullish-coalesced
# instead of fixing the source of null. The model patches the symptom (catch it,
# default it) instead of fixing why the value is invalid.
#   - `catch {}` / `catch (e) {}` with no body OR a bare return/log
#   - `x ?? defaultValue` / `x || default` on what should be a fail-fast path
#   - `try { ... } catch { return ... }` swallowing an error
# Stop: FAIL-FAST. If a function receives invalid state, throw an explicit Error;
# never catch an error only to hide it.
$swallowRe = '(?i)catch\s*(\([^)]*\))?\s*\{\s*(?://[^\n]*)?(?:\}|return\s|//\s*ignore|/\*.*\*/\s*\})'
# Note: no leading \b - the ?? operator is not a word boundary.
$coalesceRe = '\?\?\s*(?:null|undefined|0|''''|""|\[\]|\{\}|false|new\b)'
$maskingHits = 0
foreach ($a in $added) {
    if ($a -match $swallowRe) { $maskingHits++; continue }
    if ($a -match $coalesceRe) { $maskingHits++ }
}
if ($maskingHits -ge 1) {
    $vibeFlags.Add("- SYMPTOM MASKING: $maskingHits instance(s) of empty/swallowed catch or nullish-coalesced fallback detected. The model patches the symptom (`x ?? default`, `catch {} return`) instead of fixing WHY the value is invalid. Stop: FAIL-FAST. If a function receives invalid state, throw an explicit Error; never catch only to hide, never default over a value that should never be null.")
}

# (5c) BOOLEAN TRAP: a function that takes a positional boolean to switch behavior.
# `processData(data, true)` is a classic - the model uses one function + a flag
# instead of two functions or a strategy. Stop: no boolean flags; split the
# function or use a strategy/dictionary dispatch.
$boolParamRe = '(?i)\bfunction\s+\w+\s*\([^)]*\b(is[A-Z]|should[A-Z]|with[A-Z]|use[A-Z]|enable[A-Z]|disable[A-Z]|force[A-Z]|skip[A-Z]|verbose|dryRun|async|strict|deep|quick)\b\s*[:=]\s*(?:boolean|bool|true|false)[^)]*\)'
$arrowBoolRe = '(?i)(?:const|let|var|func|def|fn)\s+\w+\s*\([^)]*\b(is[A-Z]|should[A-Z]|with[A-Z]|use[A-Z]|enable[A-Z]|disable[A-Z]|force[A-Z]|skip[A-Z]|verbose|dryRun|strict|deep|quick)\??\s*[:=]\s*(?:boolean|bool|true|false)\b[^)]*\)'
$boolHits = 0
foreach ($a in $added) {
    if ($a -match $boolParamRe) { $boolHits++; continue }
    if ($a -match $arrowBoolRe) { $boolHits++ }
}
if ($boolHits -ge 1) {
    $vibeFlags.Add("- BOOLEAN TRAP: $boolHits function(s) take a positional boolean to switch behavior (is*/should*/with*/use*/enable*/force*/skip*/verbose/dryRun/strict/deep/quick). The model uses a flag instead of two functions. Stop: SPLIT the function or use a strategy/dictionary dispatch. If the behavior changes, it is a different function.")
}

# (5d) SWITCH BLOAT: a switch or if/else-if chain with > 5 cases. The model maps
# states via switch instead of a dictionary. Stop: replace with a Record<Map, Fn>
# / dictionary dispatch (Map<Estado, Funcion>), never a switch with > 5 arms.
$switchRe = '(?i)\bswitch\b'
$caseRe   = '(?i)^\s*(?:case\s|default\s*:|when\s)'
$elseifRe = '(?i)^\s*(?:}\s*)?else\s+if\b'
$caseCount = 0
$inSwitch  = $false
foreach ($a in $added) {
    if ($a -match $switchRe) { $inSwitch = $true; continue }
    if ($inSwitch -and $a -match $caseRe) { $caseCount++; continue }
    if ($a -match $elseifRe) { $caseCount++ }
}
if ($caseCount -ge 6) {
    $vibeFlags.Add("- SWITCH BLOAT: $caseCount case/branch arms detected in one switch or if/else-if chain. The model maps states via switch. Stop: DICTIONARY DISPATCH - a Record<Estado, Funcion> / Map<state, handler> lookup, never a switch with > 5 arms.")
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
$flags.AddRange($opsFlags)
$flags.AddRange($vibeFlags)

if ($flags.Count -eq 0 -and -not $substantial) { exit 0 }

# --- load the slop checklist (md preferred, embedded fallback) ------------
$checklistFile = Join-Path $HOME '.agents\hooks\anti-slop.md'
$checklist = ''
if (Test-Path -LiteralPath $checklistFile) { $checklist = Get-Content -Raw -LiteralPath $checklistFile }
if (-not $checklist) {
    $checklist = @'
ANTI-SLOP — read ~/.agents/hooks/anti-slop.md (17 items). Fallback if missing:
  1–10: edge cases, duplication, conventions, deps, premature abstraction,
  accidental complexity, tests (no tautologies), cargo cult, architecture,
  redundant comments / prompt residue.
  11: semantic contracts (behavior change without name/signature change).
  12: operational slop (retry w/o backoff, await-in-loop, telemetry spam).
  13: change surface (too many files for a simple request).
  14: SLAP - one function one abstraction level.
  15: phantom state - explicit lifecycle, no implicit call-order.
  16: primitive obsession - value objects over loose primitives with rules.
  17: loop-driven - prefer map/filter/reduce over imperative for on arrays.
Static vibe-coding signals also flagged inline when detected: arrow code,
symptom masking, boolean trap, switch bloat.
Fix guilty items now. Never revert what the user asked for.
'@
}

$flagBlock = if ($flags.Count -gt 0) { "Static signals on this edit:`n" + ($flags -join "`n") + "`n`n" } else { '' }

# Concatenate (do NOT interpolate $checklist - its content must stay literal).
# Expand ~ on the final message so the model gets literal absolute paths
# (Windows pwsh does NOT expand ~; the agent may paste paths into a shell).
$header = "Anti-slop audit - $rel`n`n"
$footer = "`n`n(Advisory; the bug pass is the self-review trigger. Disable: ANTI_SLOP_ENFORCE=0)"
$msg = Expand-AgentPaths ($header + $flagBlock + $checklist + $footer)

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
