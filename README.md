<div align="center">
  <img src="https://img.shields.io/badge/node-%3E%3D18-339933?style=flat-square&logo=node.js&logoColor=white" />
  <img src="https://img.shields.io/npm/v/cursordoctrine?style=flat-square&color=blue" />
  <img src="https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/built%20for-Cursor-6c47ff?style=flat-square" />
</div>

<br />

<div align="center">
  <h1>cursordoctrine</h1>
  <p><strong>Three hooks for Cursor. Doctrine at start, gate on shell, review at stop.</strong></p>
  <p>The model is the auditor. The harness does only what the model can't do for itself:<br />inject governing text, block irreversible shell, and ask for one end-of-session review.</p>
</div>

<br />

---

## What this is

Three Cursor hooks. No state machine, no per-edit advisories, no contract files written to your repos.

1. **Inject the doctrine** at `sessionStart` — every chat starts with the same short governing text (`doctrine.md`): smallest correct diff, YAGNI ultra, ask-don't-guess, conventional commits, the auditor mindset. ~80 lines, read once.
2. **Gate blast radius** at `beforeShellExecution` — one permission gate denies a short explicit list of dangerous commands (`rm -rf /`, `curl | sh`, force-push, `npm publish`, ...). The script fails open on internal errors; `failClosed: false` so a pwsh cold-start abort does not block all shell use. Everything else passes.
3. **One final review** at `stop` — when an implementation finishes and `git` sees changed files, Cursor auto-submits one `FINAL REVIEW` follow-up. Six axes: intent trace (tie every diff hunk to the original request — anything untraceable is a hallucinated requirement), correctness, reliability, coverage, anti-slop, wiring completeness. The hook reads `git diff --name-only HEAD` + untracked files; zero state on disk.

The model is the auditor. A self-review done by the model in its own context is free — it has the file, the diff, the user's intent, and the ability to fix. The harness's only non-advisory lever is the permission gate's hard deny.

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

The anti-slop skill (`skills/anti-slop/` — `SKILL.md` and the duplication scanner) installs to `~/.cursor/skills/anti-slop/`. The hook checklist (`~/.agents/hooks/anti-slop.md`, 21 items) is the canonical slop detector the final-review follow-up points the model at. The session final-review tells the model to apply it to the session diff; `cursordoctrine sweep` is the separate on-demand pass for accumulated slop across the whole repo.

### Session review vs. `sweep` — two jobs, two scopes

- **Session final-review** (`stop`): scans only the files `git` sees as changed this session. Fixes are limited to lines the agent added. Pre-existing slop is out of scope (axis 0 intent-trace; touching it is scope creep, and 100+ files won't fit in one bounded pass).
- **`npx cursordoctrine sweep`**: whole-repo cleanup. Runs the scanner in `--all` mode across every tracked file, prints a category-by-category breakdown, and hands off to the agent under a cleanup doctrine that authorizes fixing pre-existing slop, category by category, with a re-scan after each. Use it when you want a codebase cleanup, not on every session.

## The flows

| Flow | Event | What happens |
|---|---|---|
| Session | `sessionStart` | `inject-doctrine` reads `doctrine.md` and emits it as `additional_context`. |
| Shell | `beforeShellExecution` | `permission-gate` checks the command against a deny list. Allow by default, deny by list, **fail closed**. |
| Stop | `stop` | `final-review` reads `git diff --name-only HEAD` + untracked files, pulls the last user `<user_query>` from the transcript for intent trace, and emits one `FINAL REVIEW` follow-up if anything changed. Bounded by a per-cid one-shot brake (`reviewed-<cid>.flag`) and `loop_limit: 2`. |

## Layout

```
windows/          PowerShell 7 hooks (pwsh) — install on Windows machines
  hooks.json      3-event hook wiring for ~/.cursor/hooks.json
  inject-doctrine.ps1, doctrine.md
  hooks/          permission-gate.ps1, final-review.ps1, hook-common.ps1 (shared)
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
| `FINAL_REVIEW_ENFORCE=0` | on | disables the final review pass |

## Design notes

- **State lives under `$HOME`**, in `~/.cursor/.hooks-pending/`, keyed by conversation id. Just one file: `reviewed-<cid>.flag` (the one-shot brake for `final-review`). Stale state older than 7 days gets swept on every stop. No repo litter.
- **Change detection is stateless.** `final-review` asks `git` what changed. No marker file the agent has to maintain, no `.scope.json` contract written to every repo.
- **One review per implementation.** The stop hook arms a per-conversation flag before emitting its follow-up, so a crash can't re-fire it and a long chat still gets a review after each implementation.
- **The doctrine is short on purpose.** 80 lines the agent reads at sessionStart and internalizes. No re-injection per turn, no `.scope.json` bookkeeping — the model either understood the doctrine or it didn't, and re-injecting it 50 times doesn't fix that.

Self-contained. No build. Open `hooks.json` and read it — that's the whole system in one file.

Built with [Cursor](https://cursor.com).

## License

MIT. See [LICENSE](LICENSE).
