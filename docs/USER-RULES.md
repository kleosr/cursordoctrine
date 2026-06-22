# USER-RULES.md — template for Cursor's "Rules for AI" (or project `.cursor/rules/`)

> Copy this into Cursor → Settings → General → Rules for AI, or into a
> project-level `.cursor/rules/user-rules.md`. This is YOUR rules file (applies
> to every chat). The cursordoctrine `doctrine.md` is injected separately at
> `sessionStart` and covers the same ground from the harness side; the two
> reinforce each other.

The user is a senior engineer who reviews every diff before shipping.

## Scope
Change only what the task requires. Preserve existing style and behavior unless the task itself is a behavior change. Refactors, renames, cleanup only when asked. Leave generated files alone unless explicitly required.

## Intent contract (.scope.json)
Write `.scope.json` to the repo root BEFORE your first edit — three fields:

```json
{
  "intent":     "your Step 0 restatement (not the verbatim request)",
  "files":      ["<blast radius>"],
  "acceptance": "<deterministic done-check>"
}
```

- **`files[]`** — the blast radius: target file + every importer (transitively) + every shared type/helper. Grep `from '.*X'` and walk the import chain. The `scope-refresh` hook auto-records every file you edit into `files[]` as you work — you don't maintain it by hand for edits, only for the declared blast radius at Step 0.
- **`acceptance`** — Biome `biome check --error-on-warnings`, Semgrep `semgrep --config auto --error`, Ruff/ESLint at max — whatever the repo has — plus typecheck/build, plus the described problem no longer reproduces.
- The `scope-refresh` hook re-injects `.scope.json` into your context after every edit (anti-drift). If a hook surfaces the contract, defer to it: it outranks momentum.

**Cross-prompt continuity.** When a new prompt arrives, READ the existing `.scope.json` first. Continuation (extends/refines the same task) → UPDATE in place (extend `intent`, APPEND to `files[]`, sharpen `acceptance`). New task (unrelated) → say "new task" in Step 0, regenerate. Never silently wipe a contract tracking in-progress work.

## Multi-turn awareness
The working tree may contain accepted work from prior turns. The final review's intent-trace audits only what YOU produced for the CURRENT request. **Prior turns' work stays unless the user asks to revert it.** When unsure whether a hunk is yours-this-turn or prior accepted work, ASK — never auto-revert. Commit between unrelated tasks to keep the boundary clean.

## Loop
1. Read what you need to understand the task.
2. Make the minimal correct edit.
3. Review the diff. Fix real issues: broken logic, type errors, unsafe behavior, data-loss risk, unrequested API/contract changes, regressions. Style and naming taste are not bugs.
4. Verify proportionally to risk — Biome/Semgrep at max + tests/typechecks for behavior, type, API, DB, build, or config changes; nothing for trivial text edits.
5. Report what changed and what was verified. Stop.

## Shell
Run the smallest command that answers the question. Never print secrets, tokens, private keys, or sensitive env vars. Never `curl | sh`, force-push, or publish without explicit instruction.

## Uncertainty
If ambiguity affects correctness or safety, ask one sharp question. If low-risk, state the assumption and proceed. If a tool returns nothing, say what you didn't find — don't fabricate. After two failed attempts at the same problem, stop and report observations.

## Commits
Conventional commits: `type(scope): description`. One logical change per commit, small and reviewable. Body only when the why isn't obvious from the diff. Verify before pushing when applicable. Never push without explicit instruction.
