# cursordoctrine

Thin self-review hooks for Cursor. Five hook events, one message bus. The model is the auditor Cursor only carries context and gates blast radius.

## What this is

A small set of Cursor hooks that make the agent review its own work without bolting a static-analysis pipeline onto every keystroke. There is no regex army and no scoring engine. The hooks do three jobs:

1. **Inject the doctrine** at session start, so every chat begins with the same short governing text (`doctrine.md` + `USER-RULES.md`).
2. **Hand the model its own edits back.** After each agent edit, a self-review prompt (plus minimal-edit and anti-slop advisories when they trip) is stashed and delivered on the next turn. The model reads its own diff, fixes real bugs, and stays quiet otherwise.
3. **Gate blast radius.** One permission gate denies a short, explicit list of dangerous commands (`rm -rf /`, `curl | sh`, force-push, `npm publish`, ...). Everything else is allowed.

When an implementation finishes, a stop hook fires exactly one final review pass over everything that changed — then stops. The review runs across five axes, the first of which is **intent trace**: the hook extracts your last user message from the transcript and prepends it to the review so the model must trace every diff hunk back to a concrete request. Anything untraceable is a hallucinated requirement and gets reverted — this is the only detector that catches "clean code, wrong feature," which no later axis and no linter can see. Delegated work gets the same treatment: a subagent that edited files reviews its own implementation before its result returns to the parent, and its edits are folded into the parent's final review. Every bound is enforced twice: in the script and in `hooks.json`.

This setup is for Cursor only. It installs into `~/.cursor` and `~/.agents/hooks` and touches nothing in your projects.

## Layout

```
windows/          PowerShell hooks (pwsh) — install on Windows machines
  hooks.json      hook wiring for ~/.cursor/hooks.json
  inject-doctrine.ps1, doctrine.md, USER-RULES.md
  hooks/          the eight scripts + the three prompt files
linux/            bash hooks — install on Linux machines and SSH remotes
  hooks.json, inject-doctrine.sh, doctrine.md, USER-RULES.md
  hooks/          same hooks, ported to bash (jq preferred, python3 fallback)
skills/           Cursor agent skills shipped with the package
  anti-slop/      SKILL.md + the duplication scanner (final review runs it)
bin/              the npm CLI (npx cursordoctrine install / verify / uninstall)
INSTALL.md        a ready-to-paste prompt that tells a Cursor agent to
                  install the right folder and verify every hook
assets/           the architecture diagram above
```

The two folders are functionally identical. Windows runs everything through `pwsh.exe`; Linux runs bash, which is what you want on a remote you reach over SSH (see your `~/.ssh/config` host — the hooks live on the remote's `$HOME`, not on your laptop).

## The five flows

| Flow | Event | What happens |
|---|---|---|
| Session | `sessionStart` | `inject-doctrine` reads the doctrine + user rules and emits them as `additional_context`. |
| Every turn | `postToolUse` | Folds completed subagents' edit markers into this conversation's marker, then drains the conversation's pending feedback file into `additional_context`. One-shot, keyed by conversation id. |
| Shell | `beforeShellExecution` | `permission-gate` checks the command against a deny list. Allow by default, deny by list, fail open. |
| Edit | `afterFileEdit` + `stop` | `self-review-trigger` stashes the review prompt per edit; `minimal-edit-audit` and `anti-slop-audit` append advisories when thresholds trip (new deps / premature abstraction / redundant comments / Tier 3 operational slop: retry-without-backoff, await-in-loop, telemetry spam); `final-review` fires one end-of-implementation pass. |
| Subagent | `subagentStop` | `subagent-stop-review` fires one in-subagent final review when a delegated run edited files, before the result returns to the parent. Marker-gated and flag-braked like `final-review`. |

## Install

The fast path is npm (Node 18+):

```bash
npx cursordoctrine@latest install   # copies the hook pack into ~/.agents/hooks + ~/.cursor, merges hooks.json
npx cursordoctrine verify           # smoke-tests every hook with fake payloads, no restart needed
```

Then restart Cursor — `hooks.json` is read at startup. `install` is idempotent: re-run it to update, and entries you added to `~/.cursor/hooks.json` yourself are preserved. `npx cursordoctrine uninstall` removes the pack the same way.

No Node? Open `INSTALL.md`, paste its contents into a Cursor agent chat on the target machine, and let the agent copy the files and run the verification checklist. Or do it by hand — the copy commands are in the same file.

Prerequisites: `git` everywhere; `pwsh` on Windows; `bash` plus `jq` or `python3` on Linux.

The anti-slop skill (`skills/anti-slop/` — SKILL.md and the duplication scanner) installs to `~/.cursor/skills/anti-slop/`. The final review runs the scanner from there; if it's missing (an install from before it shipped), the review falls back to the `~/.agents/hooks/anti-slop.md` checklist instead of failing.

## Tuning and kill switches

All hooks fail open and always exit 0. Nothing here can block your session.

| Variable | Default | Effect |
|---|---|---|
| `HOOKS_ENFORCE=0` | on | turns off all advisory hooks at once |
| `PERM_GATE_ENFORCE=0` | on | disables the permission gate |
| `MINIMAL_EDITING_ENFORCE=0` | on | disables the over-edit advisory |
| `ANTI_SLOP_ENFORCE=0` | on | disables the slop advisory |
| `FINAL_REVIEW_ENFORCE=0` | on | disables the final review pass |
| `SUBAGENT_REVIEW_ENFORCE=0` | on | disables the in-subagent review pass |
| `MINIMAL_EDIT_WARN_LINES` / `MINIMAL_EDIT_FAIL_LINES` | 100 / 400 | over-edit thresholds |
| `ANTI_SLOP_CHECKLIST_LINES` | 40 | added-lines threshold for the checklist |

## Design notes

- **State lives under `$HOME`**, in `~/.cursor/.hooks-pending/`, keyed by conversation id. No repo litter, and concurrent sessions can't drain each other's prompts. Stale state older than 7 days is swept on every stop.
- **`afterFileEdit` output isn't consumed by Cursor**, so the edit hooks write to a pending file and `post-tool-use` re-emits it at the next tool boundary. That's the whole message bus.
- **One review per implementation.** The stop hook arms a per-conversation flag before emitting its follow-up, so a crash can't re-fire it and a long chat still gets a review after each implementation.
- **Subagents are first-class.** `afterFileEdit` fires inside subagents keyed by the *subagent's* conversation id, the harness normalizes agent edits (incl. `StrReplace`) to tool type `Write`, and `postToolUse` never fires for the `Task` tool — all verified by payload capture. So the matchers cover `Write|StrReplace|EditNotebook` defensively, `subagentStop` reviews the subagent in its own context, and the parent folds orphaned subagent markers (found via the `subagents/` transcript directory) into its own at every tool boundary and at stop.

Self-contained. No build. Open `hooks.json` and read it — it's the whole system in one file.
