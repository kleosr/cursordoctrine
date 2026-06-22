# Hooks — operational reference

Three hooks, three events. The `hooks.json` files (`windows/`, `linux/`) are
spec-clean: only the documented Cursor options (`command`, `timeout`,
`loop_limit`, `failClosed`). Aligns with https://cursor.com/docs/hooks.

Kill switches: any hook no-ops when `HOOKS_ENFORCE=0`; each also has its own
(`PERM_GATE_ENFORCE=0`, `FINAL_REVIEW_ENFORCE=0`). The final-review brake
state lives under `~/.cursor/.hooks-pending/`, keyed by `conversation_id`.
Never committed.

## sessionStart — inject-doctrine (.ps1/.sh)
5s. Reads `~/.cursor/doctrine.md` and emits it as `{"additional_context": ...}`
(sessionStart does NOT consume raw stdout). This is the session-scoped system
context — the only governing text the agent receives. Short on purpose.

## afterFileEdit — scope-refresh (.ps1/.sh)
5s, matcher `^Write$`. Reads `.scope.json` from the repo root and stashes a
one-line reminder (intent / files / acceptance) to `~/.cursor/.hooks-pending/
scope-<cid>.txt`. Cursor does not consume afterFileEdit output directly, so
the stash is delivered by `scope-drain` (postToolUse, fires next). Per-edit
re-injection against Salience Dilution: keeps the contract visible as a turn
fills with code. Silent when no `.scope.json` exists (trivial edits, fresh
repos). One state file, no hashes, no latches. Disable: `SCOPE_REFRESH_ENFORCE=0`.

## postToolUse — scope-drain (.ps1/.sh)
5s. Drains the per-cid `scope-<cid>.txt` stash (written by `scope-refresh`)
into `additional_context`. One-shot: the stash is deleted on read. Fires on
every postToolUse but emits nothing when no stash is present (most fires,
between edits, are silent). Disable: `SCOPE_REFRESH_ENFORCE=0`.

## beforeShellExecution — permission-gate (.ps1/.sh)
5s, `failClosed: true`. Deny a small explicit list of dangerous commands
(`rm -rf` on absolute paths, `curl|sh`, force-push, `npm publish`, ...).
Default-allow, deny-by-list. Emits canonical
`{"permission":"allow"|"deny","user_message":...}`. `failClosed: true` means
a slow pwsh cold-start that times out denies by default — the safe direction
for a security-critical gate.

## stop — final-review (.ps1/.sh)
10s, `loop_limit: 2`. ONE comprehensive end-of-implementation review across
six axes (intent trace, correctness, reliability, coverage, anti-slop,
wiring completeness). On a clean stop where files changed this session,
returns `{followup_message}` so Cursor auto-submits ONE review pass.

Change detection is stateless: `git diff --name-only HEAD` + untracked files
against the resolved repo root. No per-edit marker files, no `.scope.json`
ledger — git already knows what changed.

Bounded by the per-cid `reviewed-<cid>.flag` one-shot brake (one review per
implementation; the stop AFTER the review clears it and ends the loop).
`loop_limit: 2` is the harness-side runaway cap. Only fires on
`status === 'completed'`.

Intent trace: pulls the last human `<user_query>` from the transcript and
prepends it to the followup so the model must tie every diff hunk back to a
concrete request. Anything untraceable is a hallucinated requirement.
