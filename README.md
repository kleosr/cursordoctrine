<div align="center">
  <img src="https://img.shields.io/badge/node-%3E%3D18-339933?style=flat-square&logo=node.js&logoColor=white" />
  <img src="https://img.shields.io/npm/v/cursordoctrine?style=flat-square&color=blue" />
  <img src="https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/built%20for-Cursor-6c47ff?style=flat-square" />
</div>

<br />

<div align="center">
  <h1>cursordoctrine</h1>
  <p><strong>Thin self-review hooks for Cursor.</strong></p>
  <p>Five hook events, one message bus.<br />The model audits its own work. Cursor carries context and gates blast radius.</p>
</div>

<br />

---

## What this is

Cursor hooks that make the agent review its own edits without bolting a static-analysis pipeline onto every keystroke. No regex army, no scoring engine. Three jobs:

1. **Inject the doctrine** at session start — every chat starts with the same short governing text (`doctrine.md`, `USER-RULES.md`, and `declared-editing.md`, the YAGNI ultra ladder that stops over-building before a line gets written).
2. **Hand the model its own edits back** — after each agent edit, a self-review prompt goes into a pending file (plus minimal-edit, semantic-density, and anti-slop advisories when they trip). Next turn the model reads its diff, fixes real bugs, stays quiet otherwise.
3. **Gate blast radius** — one permission gate denies a short explicit list of dangerous commands (`rm -rf /`, `curl | sh`, force-push, `npm publish`, ...). Everything else passes.

When an implementation finishes, the stop hook runs one final review over everything that changed, then stops. Five axes. The first is **intent trace**: the hook pulls your last user message from the transcript and prepends it to the review so the model has to tie every diff hunk to a concrete request. Anything it can't trace is a hallucinated requirement and gets reverted. That's the only check that catches "clean code, wrong feature" — linters and later axes miss it.

Subagents get the same treatment. If a delegated run edited files, it reviews its own work before the result goes back to the parent. Those edits fold into the parent's final review. Every bound is enforced twice: in the script and in `hooks.json`.

Cursor only. Installs into `~/.cursor` and `~/.agents/hooks`. Doesn't touch your projects.

## Install

Node 18+:

```bash
npx cursordoctrine@latest install   # copies the hook pack into ~/.agents/hooks + ~/.cursor, merges hooks.json
npx cursordoctrine verify           # smoke-tests every hook with fake payloads, no restart needed
```

Restart Cursor after install — `hooks.json` is read at startup. `install` is idempotent; re-run to update. Entries you added to `~/.cursor/hooks.json` yourself are kept. `npx cursordoctrine uninstall` removes the pack the same way.

No Node? Open `INSTALL.md`, paste it into a Cursor agent chat on the target machine, and let the agent copy files and run the checklist. Copy commands are in the same file if you prefer doing it by hand.

Prerequisites: `git` everywhere; `pwsh` on Windows; `bash` plus `jq` or `python3` on Linux.

The anti-slop skill (`skills/anti-slop/` — SKILL.md and the duplication scanner) installs to `~/.cursor/skills/anti-slop/`. The hook checklist (`~/.agents/hooks/anti-slop.md`, 13 items) is the canonical slop detector for per-edit advisories and final-review axis 4. Final review runs the scanner from the skill path first when it's there.

## The five flows

| Flow | Event | What happens |
|---|---|---|
| Session | `sessionStart` | `inject-doctrine` reads doctrine + user rules + declared-editing and emits them as `additional_context`. |
| Every turn | `postToolUse` | Folds completed subagents' edit markers into this conversation's marker, then drains the conversation's pending feedback file into `additional_context`. One-shot, keyed by conversation id. |
| Shell | `beforeShellExecution` | `permission-gate` checks the command against a deny list. Allow by default, deny by list, fail open. |
| Edit | `afterFileEdit` + `stop` | `self-review-trigger` stashes the review prompt per edit; `minimal-edit-audit` (deprecated in 0.3.0), `semantic-density-audit`, and `anti-slop-audit` append advisories when thresholds trip (new deps / premature abstraction / redundant comments / **semantic opacity**: low-density identifiers like `DataManager`, `process()`, `utils.ts` / Tier 3 operational slop: retry-without-backoff, await-in-loop, telemetry spam); `final-review` fires one end-of-implementation pass. |
| Subagent | `subagentStop` | `subagent-stop-review` fires one in-subagent final review when a delegated run edited files, before the result returns to the parent. Marker-gated and flag-braked like `final-review`. |

## Layout

```
windows/          PowerShell hooks (pwsh) — install on Windows machines
  hooks.json      hook wiring for ~/.cursor/hooks.json
  inject-doctrine.ps1, doctrine.md, USER-RULES.md, declared-editing.md
  hooks/          the eight scripts + the three prompt files
linux/            bash hooks — install on Linux machines and SSH remotes
  hooks.json, inject-doctrine.sh, doctrine.md, USER-RULES.md, declared-editing.md
  hooks/          same hooks, ported to bash (jq preferred, python3 fallback)
skills/           Cursor agent skills shipped with the package
  anti-slop/      SKILL.md + the duplication scanner (final review runs it)
bin/              the npm CLI (npx cursordoctrine install / verify / uninstall)
INSTALL.md        ready-to-paste prompt that tells a Cursor agent to
                  install the right folder and verify every hook
```

Both folders do the same thing. Windows runs everything through `pwsh.exe`. Linux runs bash, which is what you want on a remote over SSH (check your `~/.ssh/config` host — hooks live on the remote's `$HOME`, not your laptop).

## Tuning and kill switches

All hooks fail open and always exit 0. Nothing here can block your session.

| Variable | Default | Effect |
|---|---|---|
| `HOOKS_ENFORCE=0` | on | turns off all advisory hooks at once |
| `PERM_GATE_ENFORCE=0` | on | disables the permission gate |
| `MINIMAL_EDITING_ENFORCE=0` | on | disables the over-edit advisory (deprecated in 0.3.0) |
| `SEMANTIC_DENSITY_ENFORCE=0` | on | disables the semantic-opacity advisory |
| `ANTI_SLOP_ENFORCE=0` | on | disables the slop advisory |
| `FINAL_REVIEW_ENFORCE=0` | on | disables the final review pass |
| `SUBAGENT_REVIEW_ENFORCE=0` | on | disables the in-subagent review pass |
| `MINIMAL_EDIT_WARN_LINES` / `MINIMAL_EDIT_FAIL_LINES` | 100 / 400 | over-edit thresholds |
| `ANTI_SLOP_CHECKLIST_LINES` | 40 | added-lines threshold for the checklist |

## Design notes

- **State lives under `$HOME`**, in `~/.cursor/.hooks-pending/`, keyed by conversation id. No repo litter. Concurrent sessions can't drain each other's prompts. Stale state older than 7 days gets swept on every stop.
- **`afterFileEdit` output isn't consumed by Cursor**, so edit hooks write to a pending file and `post-tool-use` re-emits it at the next tool boundary. That's the whole message bus.
- **One review per implementation.** The stop hook arms a per-conversation flag before emitting its follow-up, so a crash can't re-fire it and a long chat still gets a review after each implementation.
- **Subagents are first-class.** `afterFileEdit` fires inside subagents keyed by the subagent's conversation id. The harness normalizes agent edits (incl. `StrReplace`) to tool type `Write`, and `postToolUse` never fires for the `Task` tool — verified by payload capture. Matchers cover `Write|StrReplace|EditNotebook` defensively. `subagentStop` reviews the subagent in its own context. The parent folds orphaned subagent markers (from the `subagents/` transcript directory) into its own at every tool boundary and at stop.

Self-contained. No build. Open `hooks.json` and read it — that's the whole system in one file.

Built with [Cursor](https://cursor.com).

## License

MIT. See [LICENSE](LICENSE).
