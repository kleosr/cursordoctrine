# Agent prompt: install the cursordoctrine hooks

> Fast path: if Node 18+ is on the machine, `npx cursordoctrine@latest install`
> does step 2 (including the hooks.json merge), and `npx cursordoctrine verify`
> does step 3. Then restart Cursor and continue from step 4. The prompt below
> is the manual path for machines without Node.

> Paste everything below this line into a Cursor agent chat on the target machine.

---

Install the cursordoctrine hook package for Cursor on this machine, then verify it works. This package is for Cursor only — do not wire it into any other tool, project, or editor config.

If `node --version` shows Node 18 or newer, prefer the npm installer: run `npx cursordoctrine@latest install`, then `npx cursordoctrine verify`, then skip to step 4. Otherwise continue with the manual steps.

## 1. Ask the user which system they are on

Before touching anything, ask the user one question and wait for the answer:

> "Are you installing on **Windows** or **Linux** (including SSH remotes)?"

Do not guess from the shell you happen to be running in — a Windows machine driving an SSH remote needs the Linux package on the remote. Use the answer to pick the folder:

- **Windows** → use the `windows/` folder of this repo (PowerShell hooks, run with `pwsh.exe`).
- **Linux** → use the `linux/` folder (bash hooks).

Check the prerequisites first:

- Windows: PowerShell 7 (`pwsh`) on PATH, plus `git`. Python 3.9+ if you want the anti-slop scanner (the hooks work without it).
- Linux: `bash`, `git`, and either `jq` or `python3` (the hooks prefer `jq` and fall back to `python3`; install `jq` if neither is present). Python 3.9+ for the anti-slop scanner.

## 2. Copy the files

Windows (from the repo root, in pwsh):

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\hooks", "$HOME\.cursor" | Out-Null
Copy-Item windows\hooks\* "$HOME\.agents\hooks\" -Force
Copy-Item windows\inject-doctrine.ps1, windows\doctrine.md, windows\USER-RULES.md "$HOME\.cursor\" -Force
# hooks.json ships with ~/ placeholders; pwsh -File does NOT expand ~, so
# substitute the real profile path (forward slashes) at install time:
$h = $HOME -replace '\\', '/'
(Get-Content windows\hooks.json -Raw).Replace('~/', "$h/") | Set-Content "$HOME\.cursor\hooks.json" -NoNewline
# anti-slop skill (SKILL.md + the scanner the final-review hook runs):
New-Item -ItemType Directory -Force "$HOME\.cursor\skills" | Out-Null
Copy-Item skills\anti-slop "$HOME\.cursor\skills\" -Recurse -Force
```

Linux (from the repo root, in bash):

```bash
mkdir -p ~/.agents/hooks ~/.cursor
cp linux/hooks/* ~/.agents/hooks/
cp linux/inject-doctrine.sh linux/doctrine.md linux/USER-RULES.md ~/.cursor/
cp linux/hooks.json ~/.cursor/hooks.json
chmod +x ~/.agents/hooks/*.sh ~/.cursor/inject-doctrine.sh
# anti-slop skill (SKILL.md + the scanner the final-review hook runs):
mkdir -p ~/.cursor/skills
cp -r skills/anti-slop ~/.cursor/skills/
```

If `~/.cursor/hooks.json` already exists, merge the hook entries instead of overwriting — preserve anything the user already has.

## 3. Verify before restarting Cursor

Run each hook by hand with a fake payload and confirm the output. Every hook must exit 0; none of them may hang.

Linux:

```bash
echo '{"command":"git push --force"}' | bash ~/.agents/hooks/permission-gate.sh   # expect "permission":"deny"
echo '{"command":"git status"}'       | bash ~/.agents/hooks/permission-gate.sh   # expect {"permission":"allow"}
echo '{"conversation_id":"t1","file_path":"/tmp/x.py"}' | bash ~/.agents/hooks/self-review-trigger.sh
echo '{"conversation_id":"t1"}'       | bash ~/.agents/hooks/post-tool-use.sh     # expect {"additional_context": ...}
echo '{"conversation_id":"t1","status":"completed"}' | bash ~/.agents/hooks/final-review.sh  # expect {"followup_message": ...} once, then {}
echo '{"conversation_id":"t2","file_path":"/tmp/x.py"}' | bash ~/.agents/hooks/self-review-trigger.sh
echo '{"conversation_id":"t2","status":"completed"}' | bash ~/.agents/hooks/subagent-stop-review.sh  # expect {"followup_message": "SUBAGENT FINAL REVIEW ..."} once, then {}
echo '{"conversation_id":"t2"}'       | bash ~/.agents/hooks/post-tool-use.sh     # drain t2's leftover feedback file
echo '{}' | bash ~/.cursor/inject-doctrine.sh                                     # expect {"additional_context": ...}
python3 ~/.cursor/skills/anti-slop/scripts/scan_slop.py --help                    # expect usage text (final review's scanner)
```

If the scanner check fails, the final review still works — it falls back to the
`~/.agents/hooks/anti-slop.md` checklist — but re-run the copy step above. The
skill itself (`~/.cursor/skills/anti-slop/SKILL.md`) needs Python 3.9+ for the
scanner and nothing else.

Windows (same payloads, swap `bash ~/...sh` for `pwsh.exe -NoProfile -File $HOME\.agents\hooks\<name>.ps1`, `inject-doctrine.ps1` lives in `$HOME\.cursor`, and use `python` instead of `python3` for the scanner check):

```powershell
echo '{"command":"git push --force"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\permission-gate.ps1
echo '{"conversation_id":"t2","file_path":"C:\tmp\x.py"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\self-review-trigger.ps1
echo '{"conversation_id":"t2","status":"completed"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\subagent-stop-review.ps1  # SUBAGENT FINAL REVIEW once, then {}
python $HOME\.cursor\skills\anti-slop\scripts\scan_slop.py --help
```

Also validate the config: `~/.cursor/hooks.json` must parse as JSON.

## 4. Verify inside Cursor

1. Restart Cursor (hooks.json is read at startup).
2. Open any project and start a new agent chat. The doctrine should be in context — ask the agent "what does your doctrine say about diffs?" and it should answer from §2.
3. Have the agent make a small edit to a tracked file. On the next turn it should receive a `SELF-REVIEW TRIGGER` message.
4. Ask the agent to run `git push --force` (in a throwaway repo). The permission gate must block it.
5. Finish a small implementation and stop. A single `FINAL REVIEW` follow-up should fire — exactly once.
6. Delegate a small edit to a subagent (e.g. ask the agent to "use a generalPurpose subagent to add a comment to <file>"). The subagent should receive one `SUBAGENT FINAL REVIEW` follow-up before returning, and the parent should see `SUBAGENT WORK DETECTED` at its next tool boundary. (`subagentStop` is only read at startup — if nothing fires, restart Cursor again.)
7. Type `/anti-slop` in a chat (or say "remove the AI slop") — the anti-slop skill should load and run the scanner as its first step.

## 5. Report

Tell the user what was installed, which checks passed, and anything that failed with the exact error. Do not silently work around a failing check.

Kill switches if something misbehaves: `HOOKS_ENFORCE=0` (everything advisory off), `PERM_GATE_ENFORCE=0`, `MINIMAL_EDITING_ENFORCE=0` (deprecated in 0.3.0), `SEMANTIC_DENSITY_ENFORCE=0`, `SCOPE_GATE_ENFORCE=0`, `ANTI_SLOP_ENFORCE=0`, `FINAL_REVIEW_ENFORCE=0`, `SUBAGENT_REVIEW_ENFORCE=0`.
