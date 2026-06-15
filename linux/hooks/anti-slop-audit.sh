#!/usr/bin/env bash
# anti-slop-audit.sh - afterFileEdit "AI slop" advisory (Cursor, Linux).
#
# Companion to minimal-edit-audit.sh. That hook guards ONE slop axis -
# over-editing. This hook guards the rest of the taxonomy: the parts static
# analysis can cheaply and precisely flag, plus a self-review checklist for
# the parts it cannot.
#
#   Statically flagged (high-precision, deliberately low false-positive):
#     * new dependency added to a manifest
#     * premature abstraction: a new *Factory / *Repository / *Mediator /
#       *Strategy / *Singleton / *Facade / *Builder / *Visitor / *Decorator
#       class, or CQRS / Event-Sourcing / DDD vocabulary
#     * redundant comments that merely restate the next line of code
#     * operational slop (Tier 3): retry-without-backoff, await-in-loop,
#       telemetry spam (>= 6 log/print statements added in one edit)
#
# Fires when a static signal trips OR the edit added a substantial block of
# new source (>= ANTI_SLOP_CHECKLIST_LINES, default 40). Otherwise silent.
#
# Advisory only: never blocks, never persists state, ALWAYS exits 0.
# Disable: HOOKS_ENFORCE=0  or  ANTI_SLOP_ENFORCE=0
# Tune:    ANTI_SLOP_CHECKLIST_LINES (40)

set +e
. "$(dirname "$0")/hook-common.sh"

[ "${HOOKS_ENFORCE:-}" = "0" ] && exit 0
[ "${ANTI_SLOP_ENFORCE:-}" = "0" ] && exit 0

input="$(read_hook_stdin)"
[ -n "$input" ] || exit 0

# audit root: project from JSON (cwd, then workspace_roots), else CURSOR_PROJECT_DIR / HOME
root=""
while IFS= read -r cand; do
    [ -n "$cand" ] && [ -d "$cand" ] && { root="${cand%/}"; break; }
done <<EOF
$(json_get "$input" cwd)
$(json_get_array "$input" workspace_roots)
EOF
[ -n "$root" ] || root="${CURSOR_PROJECT_DIR:-$HOME}"
root="${root%/}"

# edited file -> repo-relative path
fp=""
for k in file_path path filename absolute_path abs_path; do
    fp="$(json_get "$input" "$k")"
    [ -n "$fp" ] && break
done
[ -n "$fp" ] || exit 0
rel="$fp"
case "$rel" in "$root"/*) rel="${rel#"$root"/}" ;; esac
if is_cursor_config_path "$fp" || is_cursor_config_path "$rel"; then exit 0; fi

# git repo?
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# --- collect ADDED lines for this file (working tree vs HEAD) --------------
added="$(git -C "$root" diff HEAD -- "$rel" 2>/dev/null |
    grep -E '^\+' | grep -vE '^\+\+\+' | cut -c2- | head -n 1500)"
if [ -z "$added" ]; then
    # untracked / brand-new file: whole file is "added"
    if ! git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        [ -f "$root/$rel" ] && added="$(head -n 1500 "$root/$rel")"
    fi
fi
[ -n "$added" ] || exit 0

base="${rel##*/}"

# --- signal 1: new dependency in a manifest --------------------------------
dep_added=0
if printf '%s' "$base" | grep -qE '^(package\.json|requirements[A-Za-z0-9._-]*\.txt|pyproject\.toml|Pipfile|go\.mod|Cargo\.toml|Gemfile|composer\.json|pom\.xml|build\.gradle(\.kts)?|packages\.config)$|\.csproj$'; then
    # Strip metadata key/value pairs that match the dependency value-shape but
    # are not dependencies (e.g. "version": "1.0.1" on every version bump).
    if printf '%s\n' "$added" |
        sed -E 's/(^|[{,])[[:space:]]*["'"'"']?(version|name|description|license|author|main|module|types|typings|type|engines|packageManager|private|sideEffects|homepage|repository|keywords|edition|rust-version|python-requires|requires-python)["'"'"']?[[:space:]]*[:=][[:space:]]*(["'"'"'][^"'"'"']*["'"'"']|[^,}[:space:]]+)//' |
        grep -qE '(^|[{,])[[:space:]]*["'"'"']?[A-Za-z@][A-Za-z0-9@._/-]*(\[[^]]*\])?["'"'"']?[[:space:]]*([:=][[:space:]]*["'"'"']?[\^~>=<*v]?[0-9]|[><=~!]=[[:space:]]*[0-9]|@[[:space:]]*\^?[0-9])'; then
        dep_added=1
    fi
fi

# --- signal 2: premature abstraction (named patterns + DDD vocabulary) -----
patterns="$(printf '%s\n' "$added" |
    grep -oE '\b(class|interface|struct|trait|protocol)[[:space:]]+[A-Z][A-Za-z0-9_]*(Factory|Repository|Mediator|Strategy|Singleton|Facade|Builder|Visitor|Decorator)\b' |
    awk '{print $NF}' | sort -u | head -n 5)"
kw="$(printf '%s\n' "$added" |
    grep -oE '\b(CQRS|Event[ -]?Sourc(e|ing)|Domain[ -]?Driven|Aggregate ?Root|Bounded ?Context)\b' |
    sort -u | head -n 5)"
patterns="$(printf '%s\n%s\n' "$patterns" "$kw" | grep -v '^$' | sort -u | head -n 5)"

# --- signal 3: redundant comments that restate the code --------------------
redundant="$(printf '%s\n' "$added" |
    grep -E '^[[:space:]]*(//|#|/\*+)[[:space:]]*(increment|decrement|loop (over|through)|iterate|returns?( the)?( result| value)?[[:space:]]*$|set[[:space:]]+[A-Za-z0-9_]+[[:space:]]+to\b|getter\b|setter\b|constructor\b|initiali[sz]e\b|instantiate\b|create (a |an |the )|declare\b|define\b|assign\b|end (of|for)\b|begin\b|start (of|the))' |
    while IFS= read -r line; do
        # Word guard: real restate-the-code comments are short (<= 6 words).
        body="$(printf '%s' "$line" | sed -E 's@^[[:space:]]*(//+|#+|/\*+|\*+)[[:space:]]*@@; s@\*/[[:space:]]*$@@')"
        wc_words="$(printf '%s' "$body" | wc -w)"
        if [ "$wc_words" -le 6 ]; then
            t="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            [ "${#t}" -gt 80 ] && t="${t:0:77}..."
            printf '%s\n' "$t"
        fi
    done | sort -u | head -n 4)"

# --- signal 4: operational slop (Tier 3) ------------------------------------
# Retry-without-backoff: a retry construct with no sleep/backoff/setTimeout in
# the added lines. Seed-grade (high precision); the model judges.
ops_flags=""
if printf '%s\n' "$added" | grep -qE '\b(retry|retryCount|retries|maxRetries|attempt)[A-Za-z0-9_]*\b'; then
    if ! printf '%s\n' "$added" | grep -qE '\b(sleep|setTimeout|backoff|back_off|exponential|jitter|delay)[A-Za-z0-9_]*\b'; then
        ops_flags="${ops_flags}- RETRY WITHOUT BACKOFF: a retry construct was added but no sleep/backoff/setTimeout is visible in this edit's added lines. Unbounded retries = retry storms + token/cost burn; add bounded backoff or confirm the runtime already throttles.
"
    fi
fi
# Awaited IO call co-occurring with a loop construct on the same edit. N+1 in
# agent/edge code, not just SQL. The model judges streaming vs serial-await.
if printf '%s\n' "$added" | grep -qE '\b(for|while|forEach|map|filter|reduce|flatMap|for[[:space:]]+await|async[[:space:]]+for)\b'; then
    if printf '%s\n' "$added" | grep -qE '\bawait[[:space:]]+(fetch|ctx\.db|ctx\.run|client\.|axios|prisma\.|supabase\.|db\.|repo\.)'; then
        ops_flags="${ops_flags}- AWAIT IN LOOP: a loop construct and an awaited IO call both appear in this edit. Sequential awaits in a loop = N+1 / serial latency; confirm whether Promise.all / a batch call / a single query is the right primitive. (If this is genuinely a streaming pattern, ignore.)
"
    fi
fi
# Telemetry spam seed: 6+ log/print statements added in one file.
log_count="$(printf '%s\n' "$added" | grep -cE '\b(console\.(log|debug|info|warn|error)|print\(|fmt\.Print|std::cout|NSLog|System\.out\.println|println!|dbg!|console\.dir)\b')"
if [ "$log_count" -ge 6 ]; then
    ops_flags="${ops_flags}- TELEMETRY SPAM: ${log_count} log/print statements added in this one edit. Debug-level telemetry that nobody reads is slop; consolidate or remove (kept only if this is a real logging entrypoint).
"
fi

# --- decide whether to fire -------------------------------------------------
added_code="$(printf '%s\n' "$added" | grep -cE '[^[:space:]]')"
checklist_lines="${ANTI_SLOP_CHECKLIST_LINES:-40}"
substantial=0
if printf '%s' "$rel" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|kts|cs|cpp|cc|cxx|c|h|hpp|rb|php|swift|scala|m|mm|sh|ps1|lua|dart|ex|exs|vue|svelte)$' &&
    [ "$added_code" -ge "$checklist_lines" ]; then
    substantial=1
fi

flags=""
[ "$dep_added" = "1" ] && flags="${flags}- DEPENDENCY: $base gained a dependency - is it necessary, or do the stdlib / existing deps already cover it?
"
[ -n "$patterns" ] && flags="${flags}- PREMATURE ABSTRACTION: $(printf '%s' "$patterns" | paste -sd, - | sed 's/,/, /g') - is there a real, present problem (2-3+ call sites that exist today) that needs it? If it is speculative, delete it and write the direct code.
"
[ -n "$redundant" ] && flags="${flags}- REDUNDANT COMMENTS: $(printf '%s' "$redundant" | paste -sd '|' -) - delete comments that restate the code; keep only WHY.
"
flags="${flags}${ops_flags}"

if [ -z "$flags" ] && [ "$substantial" = "0" ]; then exit 0; fi

# --- load the slop checklist (md preferred, embedded fallback) --------------
checklist_file="$HOME/.agents/hooks/anti-slop.md"
checklist=""
[ -f "$checklist_file" ] && checklist="$(cat "$checklist_file")"
if [ -z "$checklist" ]; then
    checklist='ANTI-SLOP SELF-REVIEW - audit the edit you just made and FIX (do not explain) any slop:
  1. Edge cases beyond the happy path (null / empty / zero / boundary / error).
  2. Duplicated logic that already exists in this repo - call it, do not re-implement.
  3. Conventions - match the file'"'"'s existing style / naming / structure / error-handling.
  4. Unnecessary dependencies - remove libs the stdlib or an existing dep covers.
  5. Premature abstraction - no Factory/Repository/Mediator/CQRS/DDD without 2-3 real call sites today.
  6. Accidental complexity - flatten indirection a junior cannot read in 30s.
  7. Tests assert real behaviour and edge cases, not just "it runs".
  8. Cargo cult - delete any construct whose reason you cannot state.
  9. Architecture - respect the project'"'"'s layering and boundaries.
 10. Redundant comments restating code - delete; keep only WHY.'
fi

flag_block=""
[ -n "$flags" ] && flag_block="Static signals on this edit:
$flags
"

msg="Anti-slop audit - $rel

${flag_block}${checklist}

(Advisory; the bug pass is the self-review trigger. Disable: ANTI_SLOP_ENFORCE=0)"

# --- append to the shared pending file --------------------------------------
cid="$(safe_conversation_id "$input")"
pending="$(hooks_pending_dir)/feedback-$cid.txt"
mkdir -p "$(dirname "$pending")" 2>/dev/null
if [ -s "$pending" ]; then
    printf '\n\n---\n\n%s' "$msg" >> "$pending" 2>/dev/null
else
    printf '%s' "$msg" >> "$pending" 2>/dev/null
fi

exit 0
