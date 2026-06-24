<div align="center">
  <img src="https://img.shields.io/badge/node-%3E%3D18-339933?style=flat-square&logo=node.js&logoColor=white" />
  <img src="https://img.shields.io/npm/v/cursordoctrine?style=flat-square&color=blue" />
  <img src="https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/built%20for-Cursor-6c47ff?style=flat-square" />
</div>

<br />

<div align="center">
  <h1>cursordoctrine</h1>
  <p><strong>Nine hooks for Cursor. Doctrine at start, Step 0 hard gate, scope tracked per edit, mid-session milestone verify + intent anchor, gate on shell, review at stop.</strong></p>
  <p>The model is the auditor. The harness does only what the model can't do for itself:<br />inject governing text, keep <code>.scope.json</code> in sync, enforce Step 0 before code edits, surface mid-session verification milestones + empty-contract nudges, block irreversible shell, and ask for one end-of-session review.</p>
</div>

<br />

---

## What this is

Nine Cursor hooks across seven events. No state machine the agent has to maintain; the only on-disk state is a one-shot brake and a scope stash under `~/.cursor/.hooks-pending/`. The single repo file is `.scope.json`, written for you so you don't have to.

1. **Seed the contract** at `beforeSubmitPrompt` — `intent-precompile` writes your prompt into `.scope.json`'s `prompt` the moment you hit send. On continuation it preserves agent-owned `intent`, `decomposition[]`, `verifications[]`, `files[]`, and `acceptance`. Automatic Jaccard topic detection resets for a dissimilar new task (threshold 0.34). When `intent` is empty or `acceptance` is the default seed, it stashes a `STEP 0 CONTRACT` reminder delivered on the first tool boundary.
2. **Inject the doctrine** at `sessionStart` — every chat starts with the same short governing text (`doctrine.md`): smallest correct diff, YAGNI ultra, ask-don't-guess, conventional commits, the auditor mindset. ~95 lines, read once.
3. **Enforce Step 0** at `preToolUse` — `step0-gate` is the second hard lever (beside the shell permission gate). It **denies** Write/StrReplace/ApplyPatch to any file except `.scope.json` when `intent` is empty, and denies a second file when `files[]` already has one entry but `decomposition[]` is still empty. Read/Grep/Shell are untouched so the agent can explore first. No `.scope.json` in the repo → fail open (non-doctrine projects).
4. **Track the blast radius** at `afterFileEdit` + `postToolUse` — `scope-refresh` records each edited file into `files[]` and stashes a one-line reminder; `scope-drain` delivers it as `additional_context` on the next tool boundary (Cursor doesn't consume `afterFileEdit` stdout, so the stash-and-drain pair carries it). Fires on ALL file edits (Write, Edit, MultiEdit, ApplyPatch, etc.), not just `Write`. Keeps the contract visible as a turn fills with code.
5. **Mid-session milestone verify (doctrine-ultra)** at `postToolUse` — `milestone-verify` runs after `scope-drain`. When the agent declares a `decomposition[]` at Step 0 (Thinker) and a step's `expected_files` are all touched without a recorded verdict, it emits `VERIFY MILESTONE step N` as `additional_context`. The agent types `ACCEPT step N` or `REVISE step N: <diagnosis>` in chat; the hook scrapes the transcript and writes the verdict into `.scope.json`'s `verifications[]`. Tri-role (Trinity-style): Thinker=decomposition at Step 0, Worker=edits, Verifier=this hook + final-review axis 7. Trivial one-liners (YAGNI rung 1) leave `decomposition[]` empty and the hook stays silent.
6. **Intent anchor (persistent contract nudge)** at `postToolUse` — `intent-anchor` re-fires when the contract is incomplete and either this conversation has never been nudged or new files were edited since the last nudge. The per-cid flag stores `filesCount:nudgeCount`. Capped at 99999 nudges per conversation (effectively unlimited). Once both fields are filled, it goes silent permanently for that conversation.
7. **Gate blast radius** at `beforeShellExecution` — one permission gate denies a short explicit list of dangerous commands (`rm -rf /`, `curl | sh`, force-push, `npm publish`, ...). The script fails open on internal errors; `failClosed: false` so a pwsh cold-start abort does not block all shell use. Everything else passes.
8. **One final review** at `stop` — when an implementation finishes and `git` sees changed files (or `.scope.json` `files[]` has entries for non-git projects), Cursor auto-submits one `FINAL REVIEW` follow-up. **Eight axes with a structured bullet report** (the model emits `- **N Axis**: PASS | FAIL — reason` per axis, then `**Verdict**: ACCEPT | REVISE`). If the agent revises based on the review, the hook detects the diff changed and re-reviews the new diff. This verify-revise-reverify cycle repeats until the diff stabilizes or `loop_limit: 3` is hit. The hook reads `git diff --name-only HEAD` + untracked files (falls back to `.scope.json` `files[]` for non-git projects); the only state is a per-conversation brake flag storing a content-hash signature of the change surface.

The model is the auditor. A self-review done by the model in its own context is free — it has the file, the diff, the user's intent, and the ability to fix. The harness's two hard levers are **step0-gate** (no code edits without a persisted contract) and the **permission gate** (no irreversible shell).

## Prerequisites

> **PowerShell 7 (`pwsh`) is required on Windows.** The hooks run via `pwsh.exe -NoProfile -File ...`. Windows PowerShell 5.1 (`powershell.exe`) is not supported — install PowerShell 7 separately.

| Platform | Required | Optional (recommended) |
|---|---|---|
| **Windows** | `git`, **PowerShell 7 (`pwsh`) on PATH** | Python 3.9+ (powers the sweep scanner) |
| **Linux / SSH remotes** | `bash`, `git`, and `jq` **or** `python3` | Python 3.9+ (sweep scanner) |

Install PowerShell 7:

- **Windows**: `winget install --id Microsoft.PowerShell --source winget` (or grab the MSI from the [PowerShell GitHub releases](https://github.com/PowerShell/PowerShell/releases)). Confirm with `pwsh -Version`.
- **Linux**: follow the [official package instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) — only needed if you run the `windows/` pack on a Linux box (unusual); normal Linux installs use the `linux/` bash pack.

## Install

Node 18+:

```bash
npx cursordoctrine@latest install   # copies the hook pack into ~/.agents/hooks + ~/.cursor, merges hooks.json
npx cursordoctrine verify           # smoke-tests every hook with fake payloads, no restart needed
npx cursordoctrine sweep            # whole-codebase anti-slop audit + fix-handoff (on demand)
```

Restart Cursor after install — `hooks.json` is read at startup. `install` is idempotent; re-run to update. Entries you added to `~/.cursor/hooks.json` yourself are kept. `npx cursordoctrine uninstall` removes the pack the same way. **Re-running `install` after upgrading to 1.0 also reaps the old hooks** (intent-precompile, intent-anchor, self-review-trigger, etc.) from your existing `hooks.json` automatically.

No Node? Open `INSTALL.md`, paste it into a Cursor agent chat on the target machine, and let the agent copy files and run the checklist.

The anti-slop skill (`skills/anti-slop/` — `SKILL.md` and the duplication scanner) installs to `~/.cursor/skills/anti-slop/`. The hook checklist (`~/.agents/hooks/anti-slop.md`, 40 items) is the canonical slop detector the final-review follow-up points the model at. The session final-review tells the model to apply it to the session diff; `cursordoctrine sweep` is the separate on-demand pass for accumulated slop across the whole repo.

### Session review vs. `sweep` — two jobs, two scopes

- **Session final-review** (`stop`): scans only the files `git` sees as changed this session. Fixes are limited to lines the agent added. Pre-existing slop is out of scope (axis 0 intent-trace; touching it is scope creep, and 100+ files won't fit in one bounded pass).
- **`npx cursordoctrine sweep`**: whole-repo cleanup. Runs the scanner in `--all` mode across every tracked file, prints a category-by-category breakdown, and hands off to the agent under a cleanup doctrine that authorizes fixing pre-existing slop, category by category, with a re-scan after each. Use it when you want a codebase cleanup, not on every session.

## The flows

| Flow | Event | What happens |
|---|---|---|
| Prompt | `beforeSubmitPrompt` | `intent-precompile` writes `prompt` (verbatim). Preserves agent fields on continuation. Automatic Jaccard topic change resets scope. Stashes `STEP 0 CONTRACT` when intent empty or acceptance default. Skips hook-generated auto-submits. Never blocks. |
| Session | `sessionStart` | `inject-doctrine` reads `doctrine.md` and emits it as `additional_context`. |
| Tool (pre) | `preToolUse` | `step0-gate` denies Write/StrReplace/ApplyPatch when `intent` is empty (always allows `.scope.json`). Denies a second file when `files[]` has one entry and `decomposition[]` is empty. Matcher-limited; `failClosed: false`. Disable: `STEP0_GATE_ENFORCE=0`. |
| Edit | `afterFileEdit` | `scope-refresh` records the edited file into `files[]` and stashes a one-line scope reminder. Fires on ALL file edits (Write, Edit, MultiEdit, ApplyPatch). |
| Tool | `postToolUse` | `scope-drain` delivers stashed reminders (`precompile-<cid>.txt` from intent-precompile, `scope-<cid>.txt` from scope-refresh) as `additional_context` (one-shot each). Then `milestone-verify` … Then `intent-anchor` re-fires when contract incomplete and never-nudged or new files edited. |
| Shell | `beforeShellExecution` | `permission-gate` checks the command against a deny list. Allow by default, deny by list, **fail open** (`failClosed: false` — an internal error or pwsh abort does not block shell). |
| Stop | `stop` | `final-review` reads `git diff --name-only HEAD` + untracked files (or `.scope.json` `files[]` for non-git), pulls `intent` from `.scope.json` (with `prompt` as source), and emits one `FINAL REVIEW` follow-up if anything changed. Eight axes (0 intent-trace … 6 mechanics … 7 role-trace if `decomposition[]` present). Bounded by a per-cid verify-revise brake (`reviewed-<cid>.flag` stores a content-hash signature; re-reviews if signature changed, ends if same) and `loop_limit: 3`. |

## Layout

```
windows/          PowerShell 7 hooks (pwsh) — install on Windows machines
  hooks.json      6-event hook wiring for ~/.cursor/hooks.json
  inject-doctrine.ps1, doctrine.md
  hooks/          intent-precompile.ps1, step0-gate.ps1, scope-refresh.ps1, scope-drain.ps1,
                  milestone-verify.ps1, intent-anchor.ps1, permission-gate.ps1,
                  final-review.ps1, hook-common.ps1 (shared)
                  + 3 prompt files: anti-slop.md, final-review.md, cleanup-doctrine.md
linux/            bash hooks — install on Linux machines and SSH remotes
  hooks.json, inject-doctrine.sh, doctrine.md
  hooks/          same hooks, ported to bash (jq preferred, python3 fallback)
skills/           Cursor agent skills shipped with the package
  anti-slop/      SKILL.md + the duplication scanner (`cursordoctrine sweep` runs it)
                  scripts/scan_slop.py, low_density.py
bin/              the npm CLI (npx cursordoctrine install / verify / sweep / uninstall)
INSTALL.md        ready-to-paste prompt that tells a Cursor agent to
                  install the right folder and verify every hook
```

Both folders do the same thing. Windows runs everything through `pwsh.exe` (PowerShell 7 — Windows PowerShell 5.1 is not supported). Linux runs bash, which is what you want on a remote over SSH (check your `~/.ssh/config` host — hooks live on the remote's `$HOME`, not your laptop).

## Tuning and kill switches

All hooks fail open and always exit 0. Nothing here can block your session.

| Variable | Default | Effect |
|---|---|---|
| `HOOKS_ENFORCE=0` | on | turns off all hooks at once |
| `PERM_GATE_ENFORCE=0` | on | disables the permission gate |
| `INTENT_PRECOMPILE_ENFORCE=0` | on | disables the `.scope.json` auto-write on prompt |
| `SCOPE_REFRESH_ENFORCE=0` | on | disables per-edit `files[]` recording + re-injection (scope-refresh + scope-drain) |
| `MILESTONE_VERIFY_ENFORCE=0` | on | disables the mid-session milestone verifier (doctrine-ultra) |
| `INTENT_ANCHOR_ENFORCE=0` | on | disables the contract nudge |
| `STEP0_GATE_ENFORCE=0` | on | disables the Step 0 hard gate on file writes |
| `FINAL_REVIEW_ENFORCE=0` | on | disables the final review pass |

## Design notes

- **State lives under `$HOME`**, in `~/.cursor/.hooks-pending/`, keyed by conversation id: `reviewed-<cid>.flag` (the verify-revise brake for `final-review`, stores a content-hash signature), `intent-anchored-<cid>.flag` (stores `filesCount:nudgeCount`), and a transient `scope-<cid>.txt` stash (written by `scope-refresh`, deleted by `scope-drain` on the next tool boundary). Stale state older than 7 days gets swept on every stop. The only repo file is `.scope.json`.
- **Change detection is stateless.** `final-review` asks `git` what changed — no marker file the agent maintains. It reads `.scope.json` for intent trace (`intent` primary, `prompt` as source) and diffs declared vs touched files; `intent-precompile` + `scope-refresh` keep the contract current without hand maintenance.
- **Verify-revise-reverify.** The stop hook stores a content-hash signature (SHA256 of the diff scoped to `files[]`) in a per-conversation flag before emitting its follow-up. If the agent revises (signature changes), the review re-fires. If the agent accepts (same signature), the loop ends. Bounded by `loop_limit: 3`.
- **The doctrine is short on purpose.** 80 lines the agent reads at sessionStart and internalizes. `.scope.json` is re-injected per edit (the contract, not the doctrine) so the blast radius stays visible — but the governing text itself is read once; re-injecting it 50 times doesn't fix a model that didn't internalize it.

Self-contained. No build. Open `hooks.json` and read it — that's the whole system in one file.

Built with [Cursor](https://cursor.com).

## License

MIT. See [LICENSE](LICENSE).
