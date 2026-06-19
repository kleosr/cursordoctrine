<div align="center">
  <img src="https://img.shields.io/badge/node-%3E%3D18-339933?style=flat-square&logo=node.js&logoColor=white" />
  <img src="https://img.shields.io/npm/v/cursordoctrine?style=flat-square&color=blue" />
  <img src="https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/built%20for-Cursor-6c47ff?style=flat-square" />
</div>

<br />

<div align="center">
  <h1>cursordoctrine</h1>
  <p><strong>Self-review hooks for Cursor — proactive and reactive.</strong></p>
  <p>Six hook events, one message bus.<br />The model compiles its intent, audits its own work, and stays on the rails. Cursor carries context and gates blast radius.</p>
</div>

<br />

---

## What this is

Cursor hooks that make the agent review its own edits without bolting a static-analysis pipeline onto every keystroke. No regex army, no scoring engine. Four jobs:

1. **Compile intent before coding** (proactive) — at session start the agent gets the doctrine plus the **Anchor Set** discipline (`pre-compile.md`): before writing code it must emit *Objective / Constraints / Scope / Deterministic success*. `intent-precompile` (`beforeSubmitPrompt`) materializes that as `.scope.json` the moment you hit send — **before the agent's first token** — with `intent` locked from the request and `acceptance` seeded (never a bare `<TODO>`), so the contract is the first artifact of the turn. `intent-anchor` then re-injects it into context every turn (regenerated when the prompt changes), so it stays in focus against Salience Dilution.
2. **Inject the doctrine** at session start — every chat starts with the same short governing text (`doctrine.md`, `USER-RULES.md`, `declared-editing.md` the YAGNI ultra ladder, and `pre-compile.md` the thin intent-compilation phase).
3. **Hand the model its own edits back** (reactive) — after each agent edit, a self-review prompt goes into a pending file (plus semantic-density, scope-gate, and anti-slop advisories when they trip). Next turn the model reads its diff, fixes real bugs, stays quiet otherwise.
4. **Gate blast radius** — one permission gate denies a short explicit list of dangerous commands (`rm -rf /`, `curl | sh`, force-push, `npm publish`, ...). Everything else passes.

When an implementation finishes, the stop hook runs one final review over everything that changed, then stops. Seven axes. The first is **intent trace**: the hook pulls your last user message from the transcript and prepends it to the review so the model has to tie every diff hunk to a concrete request. Anything it can't trace is a hallucinated requirement and gets reverted. The last is **mechanics & stack integrity** (N+1, idempotency, transactions, boundary validation, zombie listeners, god components, determinism) — patterns the regex scanner can't catch because they need semantic judgement. That's the only check that catches "clean code, wrong feature" — linters and later axes miss it.

Subagents get the same treatment. If a delegated run edited files, it reviews its own work before the result goes back to the parent. Those edits fold into the parent's final review. Every bound is enforced twice: in the script and in `hooks.json`.

Cursor only. Installs into `~/.cursor` and `~/.agents/hooks`. Doesn't touch your projects.

## Prerequisites

> **PowerShell 7 (`pwsh`) is required on Windows.** The hooks run via `pwsh.exe -NoProfile -File ...`. Windows PowerShell 5.1 (`powershell.exe`) is not supported — install PowerShell 7 separately.

| Platform | Required | Optional (recommended) |
|---|---|---|
| **Windows** | `git`, **PowerShell 7 (`pwsh`) on PATH** | Python 3.9+ (powers the anti-slop scanner; hooks work without it) |
| **Linux / SSH remotes** | `bash`, `git`, and `jq` **or** `python3` | Python 3.9+ (anti-slop scanner) |

Install PowerShell 7:

- **Windows**: `winget install --id Microsoft.PowerShell --source winget` (or grab the MSI from the [PowerShell GitHub releases](https://github.com/PowerShell/PowerShell/releases)). Confirm with `pwsh -Version`.
- **Linux**: follow the [official package instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) — only needed if you run the `windows/` pack on a Linux box (unusual); normal Linux installs use the `linux/` bash pack.

`npx cursordoctrine install` warns at the end if `pwsh` (Windows) or `bash`+`jq`/`python3` (Linux) or Python are missing, so you'll know up front.

## Install

Node 18+:

```bash
npx cursordoctrine@latest install   # copies the hook pack into ~/.agents/hooks + ~/.cursor, merges hooks.json
npx cursordoctrine verify           # smoke-tests every hook with fake payloads, no restart needed
```

Restart Cursor after install — `hooks.json` is read at startup. `install` is idempotent; re-run to update. Entries you added to `~/.cursor/hooks.json` yourself are kept. `npx cursordoctrine uninstall` removes the pack the same way.

No Node? Open `INSTALL.md`, paste it into a Cursor agent chat on the target machine, and let the agent copy files and run the checklist. Copy commands are in the same file if you prefer doing it by hand.

The anti-slop skill (`skills/anti-slop/` — SKILL.md and the duplication scanner) installs to `~/.cursor/skills/anti-slop/`. The hook checklist (`~/.agents/hooks/anti-slop.md`, 21 items) is the canonical slop detector for per-edit advisories and final-review axis 4. Final review runs the scanner from the skill path first when it's there.

## The proactive phase: the Anchor Set

The reactive stack (self-review, anti-slop, final-review) only fires *after* code exists. If the agent drifted from the request on its first token, a clean final review of the wrong feature is still the wrong feature. The pre-compile phase puts the right feature on the rails first.

`pre-compile.md` (injected at session start alongside the doctrine) asks the agent to emit, terse, before any code:

1. **OBJECTIVE** — one operational sentence. Not "improve X" but "make X return Y when Z".
2. **CONSTRAINTS** — local negations: what it will NOT do (no schema migration, no new dep, no refactor of the surrounding function).
3. **SCOPE** — files to touch (exact, derived from the objective) and files untouchable.
4. **DETERMINISTIC SUCCESS** — the one command, test, or observable check that decides done.

It then writes that contract to `.scope.json` in the repo root:

```json
{
  "intent": "make /api/login return 401 instead of 500 on a bad password",
  "files": ["src/api/login.ts", "tests/login.test.ts"],
  "acceptance": "tests/login.test.ts passes; curl /api/login with wrong password returns 401",
  "allow_growth": false
}
```

Two machine-checkable consequences:

- **`scope-gate-audit`** (afterFileEdit, opt-in via `.scope.json` existing) audits every edit against `files[]` and quotes `intent` + `acceptance` back on a violation. Editing outside the declared set is the textbook scope-creep signal.
- **final-review axis 0** (intent trace) traces every diff hunk back to `intent`. Anything untraceable is a hallucinated requirement.

**Before the agent's first token**, `intent-precompile` (`beforeSubmitPrompt`) materializes the Anchor Set: the moment you hit send it writes `.scope.json` to the repo root with `intent` locked from the prompt (which is in the event payload directly) and `acceptance` seeded with a real default — so the contract is the first artifact of the turn. `intent-anchor` (`postToolUse`) then re-injects it into context on the first tool boundary. One contract per prompt, re-injection per turn. The intent-anchor latch is armed on first fire and cleared **unconditionally** by the stop hook on every turn boundary, so the next turn re-fires and can never get stranded silenced mid-session.

The Anchor Set is skipped for trivial one-liners (typo, literal) — the `declared-editing.md` ladder's rung 1 governs when it's overkill.

### Contract first, then kept alive: `intent-precompile` + `intent-anchor`

The contract has to exist *before* the agent edits and stay in focus *as* it edits. Two hooks, two jobs:

**`intent-precompile` (`beforeSubmitPrompt`) — write it first.** This event fires right after the user hits send, before the backend request, with the user's `prompt` in the payload directly — no `<user_query>` extraction, no transcript dependency, no contamination from auto-submitted review followups. When the prompt is new (its `_intent_hash` differs from the contract on disk) it writes a fresh `.scope.json`: `intent` locked from the prompt, `files: []`, `acceptance` seeded with a real default (never a bare `<TODO>` — a placeholder that looks owned and never gets filled was the old failure mode), `_intent_hash` for change detection. It also stashes the verbatim prompt so `intent-anchor` reads the *same* ground-truth text. Same prompt on disk → left intact, preserving the agent's refined `intent`/`acceptance`/`files`. Hook-generated submits are skipped.

**`intent-anchor` (`postToolUse`, registered first so it runs before `post-tool-use` drains the bus) — keep it alive.** As a conversation fills with code, logs and errors, the token of the original request shrinks to a rounding error against recent history — *Salience Dilution* — and the agent stops checking the contract. So on the first tool boundary of every turn (per-turn latch, cleared unconditionally at each stop) it reads `.scope.json` and stashes `intent` + `files` + `acceptance` into the feedback bus, which `post-tool-use` delivers as `additional_context` — the contract back in attentional focus before edits pile up. It also **falls back to creating the contract** if `beforeSubmitPrompt` didn't run (older Cursor), and re-injects a loud demand each turn until the agent sharpens the seeded `acceptance` to the one deterministic check.

> **The hooks write `.scope.json` deliberately.** The contract must exist before the agent edits and track the request. Safeguards: (a) **never writes to `$HOME`** — if the repo root can't be resolved the hook stays silent rather than drop a ghost file; (b) **regenerates on prompt CHANGE, not every turn** — staleness is tracked via `_intent_hash` in the file, and `intent-precompile`/`intent-anchor` share one hashing helper so a same-prompt turn re-injects without rewriting; (c) **`trace.query` stays verbatim** as the audit anchor even when the agent normalizes `intent`.

Crucially, `intent-anchor` carries the **semantic** contract (`intent`/`acceptance`) into context every turn — something the path-only `scope-gate-audit` can never do. That is what makes "the agent forgot about grid symmetry while editing the right file" catchable: the symmetry requirement is re-stated in front of the model before each edit, not just checked against a file list after.

## The flows

| Flow | Event | What happens |
|---|---|---|
| Submit | `beforeSubmitPrompt` | **`intent-precompile`** writes `.scope.json` to the repo root from the prompt in the payload — **before the agent's first token** — with `intent` locked and `acceptance` seeded, and stashes the verbatim prompt for `intent-anchor`. Skips hook-generated auto-submits; hash-gated so the agent's refinements survive. |
| Session | `sessionStart` | `inject-doctrine` reads doctrine + user rules + declared-editing + **pre-compile** and emits them as `additional_context`. |
| Every turn | `postToolUse` | **`intent-anchor`** (registered first) re-injects `.scope.json` into `additional_context` at the first tool boundary of each turn — the anti-Salience-Dilution move that keeps `intent` + `acceptance` in the model's attentional focus before edits pile up, and demands the seeded `acceptance` be sharpened. Then `post-tool-use` folds subagent markers and drains the feedback file. |
| Shell | `beforeShellExecution` | `permission-gate` checks the command against a deny list. Allow by default, deny by list, fail open. |
| Edit | `afterFileEdit` + `stop` | **Proactive:** `intent-precompile` writes the contract per prompt; `intent-anchor` re-injects it each turn. **Reactive:** `self-review-trigger` stashes the review prompt per edit; `semantic-density-audit`, `scope-gate-audit` (opt-in, audits `.scope.json`), and `anti-slop-audit` append advisories when they trip; `final-review` fires one end-of-implementation seven-axis pass. |
| Subagent | `subagentStop` | `subagent-stop-review` fires one in-subagent final review when a delegated run edited files, before the result returns to the parent. Marker-gated and flag-braked like `final-review`. |

## Layout

```
windows/          PowerShell 7 hooks (pwsh) — install on Windows machines
  hooks.json      hook wiring for ~/.cursor/hooks.json
  inject-doctrine.ps1, doctrine.md, USER-RULES.md,
  declared-editing.md, pre-compile.md
  hooks/          the ten hook scripts + hook-common.ps1 (shared) + 3 prompt files
                  (anti-slop.md, self-review.md, final-review.md)
linux/            bash hooks — install on Linux machines and SSH remotes
  hooks.json, inject-doctrine.sh, doctrine.md, USER-RULES.md,
  declared-editing.md, pre-compile.md
  hooks/          same hooks, ported to bash (jq preferred, python3 fallback)
skills/           Cursor agent skills shipped with the package
  anti-slop/      SKILL.md + the duplication scanner (final review runs it)
                  scripts/scope_match.py — the .scope.json matcher shared by
                  scope-gate-audit and final-review (returns intent + acceptance)
bin/              the npm CLI (npx cursordoctrine install / verify / uninstall)
INSTALL.md        ready-to-paste prompt that tells a Cursor agent to
                  install the right folder and verify every hook
```

Both folders do the same thing. Windows runs everything through `pwsh.exe` (PowerShell 7 — Windows PowerShell 5.1 is not supported). Linux runs bash, which is what you want on a remote over SSH (check your `~/.ssh/config` host — hooks live on the remote's `$HOME`, not your laptop).

## Tuning and kill switches

All hooks fail open and always exit 0. Nothing here can block your session.

| Variable | Default | Effect |
|---|---|---|
| `HOOKS_ENFORCE=0` | on | turns off all advisory hooks at once |
| `PERM_GATE_ENFORCE=0` | on | disables the permission gate |
| `INTENT_ANCHOR_ENFORCE=0` | on | disables the thin-intent `.scope.json` scaffold + re-injection |
| `SCOPE_GATE_ENFORCE=0` | on | disables the declared-scope advisory (opt-in: only fires when `.scope.json` exists) |
| `SEMANTIC_DENSITY_ENFORCE=0` | on | disables the semantic-opacity advisory |
| `ANTI_SLOP_ENFORCE=0` | on | disables the slop advisory |
| `FINAL_REVIEW_ENFORCE=0` | on | disables the final review pass |
| `SUBAGENT_REVIEW_ENFORCE=0` | on | disables the in-subagent review pass |
| `MINIMAL_EDIT_WARN_LINES` / `MINIMAL_EDIT_FAIL_LINES` | 100 / 400 | over-edit thresholds |
| `ANTI_SLOP_CHECKLIST_LINES` | 40 | added-lines threshold for the checklist |

## Design notes

- **State lives under `$HOME`**, in `~/.cursor/.hooks-pending/`, keyed by conversation id. No repo litter. Concurrent sessions can't drain each other's prompts. Stale state older than 7 days gets swept on every stop.
- **`afterFileEdit` output isn't consumed by Cursor**, so edit hooks write to a pending file and `post-tool-use` re-emits it at the next tool boundary. That's the whole message bus.
- **One review per implementation.** The stop hook arms a per-conversation flag before emitting its follow-up, so a crash can't re-fire it and a long chat still gets a review after each implementation. The `intent-anchor` per-turn latch is separate and simpler: it's cleared **unconditionally** on every stop, so the scaffold/re-inject re-fires on the first tool of each new turn and can never get stranded silenced mid-session.
- **The `.scope.json` contract is opt-in.** No `.scope.json` in the repo root → `scope-gate-audit` stays silent and the system falls back to the `declared-editing` ladder plus the final-review footprint check. Writing the file is how the agent opts into a machine-checked scope.
- **Subagents are first-class.** `afterFileEdit` fires inside subagents keyed by the subagent's conversation id. The harness normalizes agent edits (incl. `StrReplace`) to tool type `Write`, and `postToolUse` never fires for the `Task` tool — verified by payload capture. Matchers cover `Write|StrReplace|EditNotebook` defensively. `subagentStop` reviews the subagent in its own context. The parent folds orphaned subagent markers (from the `subagents/` transcript directory) into its own at every tool boundary and at stop.

Self-contained. No build. Open `hooks.json` and read it — that's the whole system in one file.

Built with [Cursor](https://cursor.com).

## License

MIT. See [LICENSE](LICENSE).
