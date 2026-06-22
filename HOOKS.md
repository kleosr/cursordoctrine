# Hooks — operational reference

Six hooks, six events. The `hooks.json` files (`windows/`, `linux/`) are
spec-clean: only the documented Cursor options (`command`, `timeout`,
`loop_limit`, `failClosed`, `matcher`). Aligns with https://cursor.com/docs/hooks.

Kill switches: any hook no-ops when `HOOKS_ENFORCE=0`; each also has its own
(`PERM_GATE_ENFORCE=0`, `INTENT_PRECOMPILE_ENFORCE=0`, `SCOPE_REFRESH_ENFORCE=0`,
`FINAL_REVIEW_ENFORCE=0`). The final-review brake state lives under
`~/.cursor/.hooks-pending/`, keyed by `conversation_id`. Never committed.

## beforeSubmitPrompt — intent-precompile (.ps1/.sh)
5s. Fires right after the user hits send, BEFORE the agent's first token, with
the prompt in the payload directly. Writes the prompt as `.scope.json`'s
`prompt` field (hook-owned). Agent owns `intent` (Step 0 restatement).

**Continuation:** update `prompt` only; preserve `intent`, `files[]`, and
`acceptance`.

**New task:** prompt starts with `/new`, `new task:`, or `new task —` (case
insensitive) → reset `intent` to `""`, `files[]` to `[]`, `acceptance` to
default. Agent must restate.

If `.scope.json` doesn't exist, creates it fresh with empty `intent` and
`files[]`. Skips hook-generated auto-submits (FINAL REVIEW / SCOPE REMINDER /
etc.). Never blocks. No repo root → silent. Disable:
`INTENT_PRECOMPILE_ENFORCE=0`.

## sessionStart — inject-doctrine (.ps1/.sh)
5s. Reads `~/.cursor/doctrine.md` and emits it as `{"additional_context": ...}`
(sessionStart does NOT consume raw stdout). This is the session-scoped system
context — the only governing text the agent receives. Short on purpose.

## afterFileEdit — scope-refresh (.ps1/.sh)
5s, matcher `^Write$`. Reads `.scope.json` from the repo root and stashes a
one-line reminder (`prompt` / `intent` / `files` / `acceptance`) to
`~/.cursor/.hooks-pending/scope-<cid>.txt`. Cursor does not consume
afterFileEdit output directly, so the stash is delivered by `scope-drain`
(postToolUse, fires next). Per-edit re-injection against Salience Dilution:
keeps the contract visible as a turn fills with code. Silent when no
`.scope.json` exists (trivial edits, fresh repos). One state file, no hashes,
no latches. Disable: `SCOPE_REFRESH_ENFORCE=0`.

## postToolUse — scope-drain (.ps1/.sh)
5s. Drains the per-cid `scope-<cid>.txt` stash (written by `scope-refresh`)
into `additional_context`. One-shot: the stash is deleted on read. Fires on
every postToolUse but emits nothing when no stash is present (most fires,
between edits, are silent). Disable: `SCOPE_REFRESH_ENFORCE=0`.

## beforeShellExecution — permission-gate (.ps1/.sh)
5s, `failClosed: false`. Deny a small explicit list of dangerous commands
(`rm -rf` on absolute paths, `curl|sh`, force-push, `npm publish`, ...).
Default-allow, deny-by-list. Emits canonical
`{"permission":"allow"|"deny","user_message":...}`. The script itself fails
open on parse/runtime errors. `failClosed: false` matches that: if Cursor's
hook runner aborts pwsh before the script returns (cold-start timeout, signal),
shell is not blocked. Set `failClosed: true` in your merged `hooks.json` only
if you prefer deny-on-timeout over availability.

## stop — final-review (.ps1/.sh)
30s, `loop_limit: 2`. ONE comprehensive end-of-implementation review across
six axes (intent trace, correctness, reliability, coverage, anti-slop,
wiring completeness). On a clean stop where files changed this session,
returns `{followup_message}` so Cursor auto-submits ONE review pass.

Change detection is stateless: `git diff --name-only HEAD` + untracked files
against the resolved repo root. No per-edit marker files, no `.scope.json`
ledger — git already knows what changed.

Bounded by the per-cid `reviewed-<cid>.flag` one-shot brake (cleared on the
post-review stop when the last user turn was hook-generated or `loop_count > 0`;
orphaned flags from a missed follow-up are cleared and review re-fires).
`loop_limit: 2` is the harness-side runaway cap. Only fires on
`status === 'completed'`.

Intent trace: pulls `intent` from `.scope.json` (agent restatement), quotes
`prompt` as source when both exist, else falls back to the last human
`<user_query>` from the transcript. Anything untraceable is a hallucinated
requirement.
