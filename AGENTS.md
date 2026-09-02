# AGENTS.md — cursordoctrine agent handbook

Handbook for coding agents operating in this repository.

## Rules

### Core Philosophy
- Minimality over cleverness, deletion over addition, boring implementations over novelty.
- Efficiency over speed: the best code is the code never written; what gets written is clean, test-backed, and minimal.
- Before adding anything, climb the ladder: don't build -> reuse -> stdlib -> platform -> installed dep -> one line -> minimum code.
- No new abstraction without a request. No new dependency if avoidable. No boilerplate nobody asked for. Fewest files possible.
- Shortest working diff wins, but only once the problem is understood: the smallest change in the wrong place is a second bug.
- Bug fix = root cause, not symptom. Fix the shared function once; do not patch one caller and leave siblings broken.
- For throwaway scripts or one-off migrations, prefer minimum working code and leave a one-line comment if a rule was skipped for a named reason.

### Engineering Standards
- Meaningful input validation at trust boundaries.
- Explicit error handling that prevents data loss; no empty catches.
- Log unexpected errors with context, never secrets.
- Accessibility is not optional.
- Tests/verification green before done.

### Communication
- Answer in a direct report style or adapt explicitly to the user's chosen tone.
- State what changed, what was verified, and what, if anything, is left.
- Do not promise work not done. Do not invent progress.
- Question complex requests: "Do you actually need X, or does Y cover it?"

### Shell and Git Boundaries
- Never force-push (`git push --force`, `git push -f`).
- Never run destructive commands without explicit instruction: `rm -rf /`, `curl | sh`, `wget | sh`, `git reset --hard`, `git clean -fd`, `npm publish`, `pnpm publish`, `yarn publish`, `npx ... publish`, `dd ... /dev/(zero|random|urandom)`, `mkfs.*`, `chmod -R /`, `chown -R /`.

### Step 0 Gate and Scope Protocol
- When `.scope.json` exists in repository root:
  - Fill `intent` (restatement of task) and sharp deterministic `acceptance` before making code edits.
  - Multi-file changes require a declared `decomposition[]` array.
  - Do not edit `prompt` (hook-owned).

### Session Stop and Review
- Stop gate audits changes across eight axes: Intent trace, Correctness, Minimality, No overengineering, Root cause (bug fixes), Boring and reversible, Wiring and contracts, Ship discipline.
- Claiming done without running and citing checks fails Ship discipline.

## Skills

Reusable task recipes belong in `.agents/skills`. This repository currently defines no task recipes in that directory.

## Workflows

### Prerequisites
- Node.js >= 18 on PATH.

### Commands
- Verify hook pack: `npm run verify` (runs `node bin/cli.mjs verify`)
- Test installation into target home: `npm run hooks:install` (runs `node bin/cli.mjs install`)
- Test uninstallation: `npm run uninstall` (runs `node bin/cli.mjs uninstall`)
- CLI help: `node bin/cli.mjs help`

### Verification
Run `npm run verify` to test:
1. `inject-doctrine` injects doctrine context
2. `step0-gate` allows read tools
3. `step0-gate` denies writes when `.scope.json` has empty `intent`
4. `permission-gate` denies forbidden shell commands (`git push --force`)
5. `permission-gate` allows standard shell commands (`git status`)
6. `final-review` emits review follow-up on completed status

## Memory

This repository does not maintain a `docs/` directory or versioned agent memory files.
When agent memory is introduced, persist it as versioned markdown under `docs/` rather than vendor memory features.
