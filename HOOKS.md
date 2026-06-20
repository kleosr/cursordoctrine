# Hooks — operational reference

The `hooks.json` files (`windows/`, `linux/`) are kept spec-clean: only the
documented Cursor options (`command`, `timeout`, `matcher`, `loop_limit`,
`failClosed`). The rationale for each hook lives here. Aligns with
https://cursor.com/docs/hooks.

Kill switches: any hook no-ops when `HOOKS_ENFORCE=0`; each also has its own
(`<NAME>_ENFORCE=0`). Hook state lives under `~/.cursor/.hooks-pending/`,
keyed by `conversation_id`. Never committed.

## beforeSubmitPrompt — intent-precompile (.ps1/.sh)
5s. **Contract-first.** Fires right after the user hits send, BEFORE the
agent's first token, with the user's `prompt` in the payload directly.
Writes/regenerates `.scope.json` (intent locked from the prompt, acceptance
seeded with a real default — never a bare `<TODO>`) so the contract is the
FIRST artifact of the turn instead of appearing late once postToolUse can
read the transcript. Stashes the verbatim prompt to `current-prompt-<cid>.txt`
so intent-anchor (postToolUse) re-injects from the SAME ground-truth text — no
`<user_query>` contamination, no `_intent_hash` fights. Skips hook-generated
auto-submits (FINAL REVIEW / SUBAGENT / SELF-REVIEW / INTENT REFINEMENT
REQUIRED). Hash-gated: same prompt on disk → left intact. Never blocks, exits 0.

## sessionStart — inject-doctrine (.ps1/.sh)
5s. Inject the agent doctrine + user rules at session start. Reads
`~/.cursor/doctrine.md` + `USER-RULES.md` (+ `declared-editing.md` +
`pre-compile.md`) and emits them as `{"additional_context": ...}` (sessionStart
does NOT consume raw stdout). This is the session-scoped system context.

## afterFileEdit — four advisory hooks (matcher: `^Write$`)
Matcher is anchored `^Write$` — Cursor normalizes agent file edits (incl.
StrReplace) to tool type `Write` in this event (verified via payload capture).
Anchored so `TabWrite` (every user tab-completion) stays excluded. The model
is the auditor; none of these block.

Fires inside subagent contexts too, keyed by the SUBAGENT's `conversation_id`
— see subagentStop + the marker fold in post-tool-use / final-review.

- **self-review-trigger** (5s) — record the edit in
  `session-edits-<cid>.txt` (the footprint ledger final-review audits) and
  stash the self-review prompt in `feedback-<cid>.txt`.
- **semantic-density-audit** (15s) — flags identifiers that communicate no
  intent (`DataManager`, `process()`, `utils.ts`, `CoreEngine`). FAIL = bare
  low-density token; WARN = defensible DDD with domain noun (only alongside a
  FAIL so clean code stays quiet). Appends to pending; never blocks.
- **scope-gate-audit** (10s, Compuerta 1) — OPT-IN (only when `.scope.json`
  exists). APPENDS every edited file to `files[]` (drops placeholder, dedups,
  preserves other fields) via jq + python3 fallback, so `files[]` is always an
  accurate ledger. The agent never maintains it by hand. No `.scope.json` =
  silent. Never blocks.
- **anti-slop-audit** (15s) — git-diff flags new deps / premature abstractions
  (Factory/Repository/Mediator/CQRS/DDD) / redundant comments, and injects the
  `anti-slop.md` checklist on substantial edits (≥ 40 lines). Never blocks.

## postToolUse — intent anchor + bus drain (no matcher: every tool)
- **intent-anchor** (5s, registered FIRST) — thin intent compilation against
  Salience Dilution. On the FIRST tool boundary of each turn (per-turn latch
  `intent-injected-<cid>.flag`, cleared unconditionally at every stop):
  (1) re-injects the existing `.scope.json` (intent/files/acceptance) into
  additional_context so the contract is back in focus before edits pile up —
  UNCONDITIONAL, no transcript needed; (2) regenerates the contract when the
  current request hash differs from `last-query-<cid>.hash`. Advisory only.
- **post-tool-use** (5s) — (1) fold completed subagents' session-edits markers
  into this conversation's marker (subagent edits fire afterFileEdit under the
  SUBAGENT's cid; postToolUse does NOT fire for the Task tool — verified by
  payload logging — so per-tool-boundary folding is how delegated edits reach
  the parent's stop review); (2) drain this conversation's `feedback-<cid>.txt`
  (self-review + advisories) into additional_context. One-shot per fire.

## subagentStop — in-subagent final review (NO matcher, loop_limit: 3)
5s. ONE seven-axis review per implementation before the result returns to the
parent. **No matcher** — fires for every subagent type, but a read-only
subagent (`explore`/`shell` that never edits) has no marker and no
`modified_files`, so it emits `{}` and stays silent. This covers ALL
editing-capable types (`generalPurpose`, Cursor's internal poteto / best-of-N
/ manual-edit-applier, and any future type) without depending on undocumented
type names.

Edit detection is belt-and-suspenders: the per-cid `session-edits-<cid>.txt`
marker (authoritative, drained on read) **UNION** the `modified_files[]` field
Cursor puts in the subagentStop payload itself (cid-independent). The payload
fallback covers the case where subagentStop surfaces the PARENT's
`conversation_id` instead of the subagent's — the marker lookup would miss,
but `modified_files` still names the files. If both are empty, nothing was
edited → `{}`.

Bounded by the per-cid `reviewed-<cid>.flag` one-shot brake (one review per
implementation; a resumed subagent with a second implementation gets a second
review) and `loop_limit: 3` harness-side. Only on `status === 'completed'`.
The parent's stop-hook fold (post-tool-use / final-review, which scans the
`subagents/` dir, cid-independent) is the ultimate backstop.

## beforeShellExecution — permission-gate (timeout: 5, failClosed: false)
Deny a small explicit list of dangerous commands (`rm -rf` on absolute paths,
`curl|sh`, force-push, `npm publish`, ...). Default-allow, deny-by-list.
Emits canonical `{"permission":"allow"|"deny","user_message":...}`.
**Note:** `failClosed: false` is the current setting — on a slow pwsh
cold-start the hook can time out and fail OPEN (dangerous commands allowed
through). For a security-critical gate the Cursor docs recommend
`failClosed: true`; flip it if you want deny-on-failure semantics.

## stop — final review (loop_limit: 5)
10s. ONE comprehensive end-of-implementation review across seven axes
(intent trace, correctness, reliability, coverage, anti-slop, wiring,
mechanics). If the agent edited files this loop (`session-edits-<cid>` marker
+ subagent fold), returns `{followup_message}` so Cursor auto-submits ONE
review pass. Also hosts the **intent enforcement gate** (Tier −1): if
`.scope.json`'s `intent` is still byte-identical to `trace.query`, it forces a
sharp one-edit followup (at most once per prompt) to make the agent do its
Step 0 restatement before any review — a verbatim intent is auditing the wrong
contract. Bounded by the per-cid `reviewed-<cid>.flag` (one review per
implementation); `loop_limit: 5` is the harness-side runaway cap, applied
per-script.
