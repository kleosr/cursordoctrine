# Hooks — operational reference

Ten agent hooks plus `inject-doctrine` across seven events. The `hooks.json` files (`windows/`, `linux/`) are
spec-clean: only the documented Cursor options (`command`, `timeout`,
`loop_limit`, `failClosed`, `matcher`). Aligns with https://cursor.com/docs/hooks.

Kill switches: any hook no-ops when `HOOKS_ENFORCE=0`; each also has its own
(`PERM_GATE_ENFORCE=0`, `INTENT_PRECOMPILE_ENFORCE=0`, `STEP0_GATE_ENFORCE=0`,
`SCOPE_REFRESH_ENFORCE=0`, `MILESTONE_VERIFY_ENFORCE=0`, `INTENT_ANCHOR_ENFORCE=0`,
`FINAL_REVIEW_ENFORCE=0`).
The final-review brake state lives under `~/.cursor/.hooks-pending/`, keyed by
`conversation_id`. Never committed.

## beforeSubmitPrompt — intent-precompile (.ps1/.sh)
5s. Fires right after the user hits send, BEFORE the agent's first token, with
the prompt in the payload directly. Writes the prompt as `.scope.json`'s
`prompt` field (hook-owned). Agent owns `intent` (Step 0 restatement),
`decomposition[]` (Thinker plan), and `acceptance`. Hook also owns
`verifications[]` (written by `milestone-verify`) and `files[]` (appended by
`scope-refresh`).

Cursor Plan Mode prompts are skipped. If Cursor exposes a plan/planning mode
field in the hook payload, that wins; otherwise only obvious plan-only text is
skipped. Implementation prompts such as "implement the plan" still seed the
contract.

**Continuation:** update `prompt` only; preserve `intent`, `decomposition[]`,
`verifications[]`, `files[]`, and `acceptance`.

**New task (automatic):** when the new prompt is dissimilar enough from the
stored prompt (Jaccard token overlap below 0.34; env override
`INTENT_TOPIC_THRESHOLD`), reset `intent` to `""`, `decomposition[]` to `[]`,
`verifications[]` to `[]`, `files[]` to `[]`, `acceptance` to default, and
clear per-conversation nudge throttle flags. Agent must restate. Optional human
signal: prefix with `/new` or `new task:` — not required by the hook.

**Step 0 nudge:** when `intent` is empty or `acceptance` is still the default
seed after seeding, stashes a `STEP 0 CONTRACT` reminder to
`~/.cursor/.hooks-pending/precompile-<cid>.txt`. `scope-drain` delivers it on
the first `postToolUse` boundary (one-shot). Resets `intent-anchor` throttle
so edit-time nudges can fire again this turn.

If `.scope.json` doesn't exist, creates it fresh with empty `intent`,
`decomposition[]`, `verifications[]`, and `files[]`. Skips hook-generated
auto-submits (FINAL REVIEW / SCOPE REMINDER / VERIFY MILESTONE / etc.). Never
blocks. No repo root → silent. Disable: `INTENT_PRECOMPILE_ENFORCE=0`.

## sessionStart — inject-doctrine (.ps1/.sh)
5s. Reads `~/.cursor/doctrine.md` and emits it as `{"additional_context": ...}`
(sessionStart does NOT consume raw stdout). This is the session-scoped system
context — the only governing text the agent receives. Short on purpose.

## preToolUse — step0-gate (.ps1/.sh)
5s, `failClosed: false`, matcher `Write|StrReplace|ApplyPatch|Edit|MultiEdit|Replace`. Hard Step 0
enforcement — the second non-advisory lever (beside `permission-gate`).

**Always allow:** writes targeting `.scope.json` (agent must fill the contract).

**Deny** other file writes when:
- `intent` is empty, whitespace-only, or still `[DRAFT]`; or
- `files[]` already has >=1 real entry (non-placeholder, not `.scope.json`) AND
  `decomposition[]` is empty (multi-file work needs a plan before file 2).

**Fail open when:** no `.scope.json`; project root cannot be resolved; target
path cannot be parsed from `tool_input`; internal parse/runtime error; kill
switch set. Read/Grep/Shell are not matched — explore first, contract second.

Emits `{"permission":"deny","user_message":...,"agent_message":...}`. Disable:
`STEP0_GATE_ENFORCE=0`.

## afterFileEdit — scope-refresh (.ps1/.sh)
5s. Reads `.scope.json` from the repo root and stashes a
one-line reminder (`prompt` / `intent` / `files` / `acceptance`) to
`~/.cursor/.hooks-pending/scope-<cid>.txt`. Cursor does not consume
afterFileEdit output directly, so the stash is delivered by `scope-drain`
(postToolUse, fires next). Per-edit re-injection against Salience Dilution:
keeps the contract visible as a turn fills with code. Silent when no
`.scope.json` exists (trivial edits, fresh repos). One state file, no hashes,
no latches. No matcher — fires on ALL file edits (Write, Edit, MultiEdit,
ApplyPatch, etc.), not just `Write`. Saved Cursor plans under
`.cursor/plans/**` are ignored. Disable: `SCOPE_REFRESH_ENFORCE=0`.

## postToolUse — scope-drain + scope-git-sweep + milestone-verify + intent-anchor (.ps1/.sh)
5s each. Four entries run in array order.

**scope-drain:** Drains the per-cid `scope-<cid>.txt` stash (written by
`scope-refresh`) and/or `precompile-<cid>.txt` (written by `intent-precompile`)
into `additional_context`. One-shot: each stash is deleted on read. Fires on
every postToolUse but emits nothing when no stash is present (most fires, between
edits, are silent). Disable: `SCOPE_REFRESH_ENFORCE=0`.

**scope-git-sweep:** After Shell/Bash tool calls, unions git-changed paths into
`files[]` that were modified after the per-cid `session-start-<cid>.txt`
timestamp (written at `sessionStart` by `inject-doctrine` and on first prompt by
`intent-precompile`). Pre-session dirty/untracked files are ignored. Never emits
`additional_context` — only maintains `files[]`. Disable: `SCOPE_REFRESH_ENFORCE=0`.

**milestone-verify (doctrine-ultra):** Tri-role Verifier. When `.scope.json`
declares a non-empty `decomposition[]` AND a step's `expected_files[]` are all
in `files[]` AND no verdict is recorded for that step in `verifications[]`,
emit `VERIFY MILESTONE step N of M` as `additional_context`. The agent emits
`ACCEPT step N` or `REVISE step N: <one-line diagnosis>` in chat; the hook
scrapes the transcript backward through assistant turns for the most recent
verdict and writes it into `verifications[]` (hook-owned).

Silent when: `.scope.json` missing; all steps already verified; no
expected_files completed; kill switch set; (Linux) no python3 available
(verdict-scrape needs regex on transcript text). When `decomposition[]` is
empty BUT the session has touched >= 2 files, a `DECOMPOSE` nudge fires
instead of going silent: the doctrine requires decomposition for multi-file
tasks, and this closes the gap where an agent touches many files with zero
steps declared. Per-cid flag throttle (mirrors intent-anchor) re-nudges only
when `files[]` grows, capped at 99999 (env override `DECOMPOSE_NUDGE_CAP`). The
final review's axis 7 is the backstop: a multi-file task with no decomposition
FAILs. Never blocks. Disable: `MILESTONE_VERIFY_ENFORCE=0`.

**intent-anchor (persistent contract nudge):** Re-fires when the contract is
still incomplete (empty `intent`, stale `[DRAFT]`, or default-seed `acceptance`)
AND either (a) this conversation has never been nudged yet, or (b) `files[]`
has grown since the last nudge. The per-cid flag (`intent-anchored-<cid>.flag`)
stores `filesCount:nudgeCount`. Once both `intent` and sharpened `acceptance`
are filled, the hook goes silent permanently for that conversation. The nudge
cap is 99999 per conversation (env override `INTENT_ANCHOR_NUDGE_CAP`); the
final review's axis 0 FAIL is the backstop at stop time. Emits an `INTENT ANCHOR`
reminder listing which agent-owned field is missing. The hook never writes
those fields — it just surfaces the gap so final-review's axis 0 intent trace
has something better than the raw prompt to work with. Disable:
`INTENT_ANCHOR_ENFORCE=0`.

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
30s, `loop_limit: 3`. ONE comprehensive end-of-implementation review across
eight axes (0 intent trace, 1 correctness, 2 reliability, 3 coverage, 4
anti-slop, 5 wiring completeness, 6 mechanics, 7 role-trace if
`decomposition[]` was declared). On a clean stop where files changed this
session, returns `{followup_message}` so Cursor auto-submits ONE review pass.

Change detection is session-scoped: when `.scope.json` is present,
`files[]` (maintained by scope-refresh on every afterFileEdit) is the
authoritative per-session edit surface. Empty `files[]` means the agent made
no session edits, so the review does NOT fire (read-only turns skip). This was
the root fix: previously `git diff HEAD` was preferred, which counted
pre-existing uncommitted files the agent only READ as "changed this session."
Non-doctrine projects (no `.scope.json`) fall back to
`git diff --name-only HEAD` + untracked files against the resolved repo root.
The diff stat is injected as evidence so the model audits with real numbers.
No per-edit marker files.

Saved Cursor Plan Mode artifacts under `.cursor/plans/**` are ignored in every
change-surface path (scope-refresh, scope-git-sweep, final-review, and the
review brake signature). Planning files do not enter `files[]` and do not cause
a final review by themselves.

Bounded by the per-cid `reviewed-<cid>.flag` verify-revise brake. The flag
stores a CONTENT-HASH SIGNATURE (SHA256 of `git diff HEAD -- <files[]>` for
doctrine, or `git diff HEAD` + untracked for non-doctrine) at review time.
On the post-review stop, if the signature CHANGED (the agent revised), the
review RE-FIRES with the new diff. If the signature is the SAME (agent
accepted), the flag clears and the loop ends. This implements the
verify-revise-reverify cycle: review, fix, re-review until the diff
stabilizes. Bounded by `loop_limit: 3` (review, revise, re-review).
Orphaned flags from a missed follow-up are cleared and review re-fires.
Only fires on `status === 'completed'`.

Intent trace: pulls `intent` from `.scope.json` (agent restatement), quotes
`prompt` as source when both exist, else falls back to the last human
`<user_query>` from the transcript. If `intent` is empty or still `[DRAFT]`
(from a legacy install), a CONTRACT GAP note is prepended and axis 0 FAILs
until the agent writes a restatement. Anything untraceable is a hallucinated
requirement.

Role-trace (axis 7): when `.scope.json` has a non-empty `decomposition[]`,
the follow-up includes a per-step status block: each step shows whether its
`expected_files` were touched and what verdict was recorded. Touched files
that aren't in any step's `expected_files` are flagged as cross-step leakage.
When `decomposition[]` is empty on a MULTI-FILE task (>=2 files), a CONTRACT
GAP block is injected and axis 7 FAILs (not SKIP) until a plan is declared —
only a genuine single-file one-liner SKIPs axis 7 (YAGNI rung 1).
