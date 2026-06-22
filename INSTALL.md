# Agent prompt: install the cursordoctrine hooks

> Fast path: if Node 18+ is on the machine, `npx cursordoctrine@latest install`
> does step 2 (including the hooks.json merge), and `npx cursordoctrine verify`
> does step 3. Then restart Cursor and continue from step 4. The prompt below
> is the manual path for machines without Node. Run `npx cursordoctrine sweep`
> on demand for a whole-codebase anti-slop cleanup.

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

- Windows: **PowerShell 7 (`pwsh`) on PATH**, plus `git`. Python 3.9+ if you want the anti-slop scanner (`cursordoctrine sweep` uses it). Confirm with `pwsh -Version` — Windows PowerShell 5.1 (`powershell.exe`) is NOT supported; install PowerShell 7 via `winget install --id Microsoft.PowerShell --source winget` if missing.
- Linux: `bash`, `git`, and either `jq` or `python3` (the hooks prefer `jq` and fall back to `python3`; install `jq` if neither is present). Python 3.9+ for the sweep scanner.

## 2. Copy the files

Windows (from the repo root, in pwsh):

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\hooks", "$HOME\.cursor" | Out-Null
Copy-Item windows\hooks\* "$HOME\.agents\hooks\" -Force
Copy-Item windows\inject-doctrine.ps1, windows\doctrine.md "$HOME\.cursor\" -Force
# hooks.json ships with ~/ placeholders; pwsh -File does NOT expand ~, so
# substitute the real profile path (forward slashes) at install time:
$h = $HOME -replace '\\', '/'
(Get-Content windows\hooks.json -Raw).Replace('~/', "$h/") | Set-Content "$HOME\.cursor\hooks.json" -NoNewline
# anti-slop skill (SKILL.md + the scanner the sweep command runs):
New-Item -ItemType Directory -Force "$HOME\.cursor\skills" | Out-Null
Copy-Item skills\anti-slop "$HOME\.cursor\skills\" -Recurse -Force
```

Linux (from the repo root, in bash):

```bash
mkdir -p ~/.agents/hooks ~/.cursor
cp linux/hooks/* ~/.agents/hooks/
cp linux/inject-doctrine.sh linux/doctrine.md ~/.cursor/
cp linux/hooks.json ~/.cursor/hooks.json
chmod +x ~/.agents/hooks/*.sh ~/.cursor/inject-doctrine.sh
# anti-slop skill (SKILL.md + the scanner the sweep command runs):
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
# final-review needs a git repo to find changes. Seed a tiny one and modify a file:
mkdir -p /tmp/cd-verify && cd /tmp/cd-verify && git init -q && echo a > f.txt && git add . && git commit -q -m init && echo b > f.txt
echo '{"conversation_id":"t1","status":"completed","cwd":"/tmp/cd-verify"}' | bash ~/.agents/hooks/final-review.sh   # expect {"followup_message": ...}
echo '{"conversation_id":"t1","status":"completed","cwd":"/tmp/cd-verify"}' | bash ~/.agents/hooks/final-review.sh   # expect {} (brake armed)
echo '{}' | bash ~/.cursor/inject-doctrine.sh                                # expect {"additional_context": ...}
python3 ~/.cursor/skills/anti-slop/scripts/scan_slop.py --help               # expect usage text
rm -rf /tmp/cd-verify
```

Windows (same payloads, swap `bash ~/...sh` for `pwsh.exe -NoProfile -File $HOME\.agents\hooks\<name>.ps1`, `inject-doctrine.ps1` lives in `$HOME\.cursor`, and use `python` instead of `python3`):

```powershell
echo '{"command":"git push --force"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\permission-gate.ps1
mkdir C:\tmp\cd-verify -Force; Set-Location C:\tmp\cd-verify; git init -q; 'a' | Out-File f.txt; git add .; git commit -q -m init; 'b' | Out-File f.txt
echo '{"conversation_id":"t1","status":"completed","cwd":"C:/tmp/cd-verify"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\final-review.ps1
echo '{"conversation_id":"t1","status":"completed","cwd":"C:/tmp/cd-verify"}' | pwsh.exe -NoProfile -File $HOME\.agents\hooks\final-review.ps1
echo '{}' | pwsh.exe -NoProfile -File $HOME\.cursor\inject-doctrine.ps1
python $HOME\.cursor\skills\anti-slop\scripts\scan_slop.py --help
Remove-Item C:\tmp\cd-verify -Recurse -Force
```

Also validate the config: `~/.cursor/hooks.json` must parse as JSON.

## 4. Verify inside Cursor

1. Restart Cursor (hooks.json is read at startup).
2. Open any project and start a new agent chat. The doctrine should be in context — ask the agent "what does your doctrine say about diffs?" and it should answer from §1 and §3.
3. Ask the agent to run `git push --force` (in a throwaway repo). The permission gate must block it.
4. Finish a small implementation in a git repo and stop. A single `FINAL REVIEW` follow-up should fire — exactly once. The follow-up lists the files git sees as changed (tracked diff + untracked new files), prepends your last user message for intent trace, and asks the model to audit across six axes.
5. Type `/anti-slop` in a chat (or say "remove the AI slop") — the anti-slop skill should load and run the scanner as its first step.
6. (Optional) Run `npx cursordoctrine sweep` for a whole-codebase anti-slop audit with a category-by-category breakdown and a cleanup handoff.

## 5. Report

Tell the user what was installed, which checks passed, and anything that failed with the exact error. Do not silently work around a failing check.

Kill switches if something misbehaves: `HOOKS_ENFORCE=0` (everything off), `PERM_GATE_ENFORCE=0`, `FINAL_REVIEW_ENFORCE=0`.
