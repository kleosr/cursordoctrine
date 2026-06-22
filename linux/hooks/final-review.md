Re-read the diff first; scope to your session's changes. Run the axes in order.
Untraceable or hallucinated work reverts; everything else gets fixed in place.
If an axis is clean, one line — don't manufacture work.

## 0. Intent trace (run first — outranks all)
Every diff hunk traces to the ORIGINAL REQUEST above. Anything that doesn't is
a HALLUCINATED REQUIREMENT — feature, flag, refactor, abstraction, dep, or
"nice to have" nobody asked for. Revert each. "Clean code, wrong feature" is
the worst failure; no later axis catches it. (No ORIGINAL REQUEST → sandboxed
run → skip.) If `.scope.json` exists, the header also carries a **Declared
scope** block: every file in the blast radius you declared at Step 0 vs what
git sees touched. Files you declared but didn't touch — did you miss them, or
did they not need changes? Files you touched but didn't declare — that's scope
creep, justify or revert.

## 1. Correctness
Logic does what the task requires. Edge cases: null / empty / zero / negative /
boundary / very-large (happy path is not enough). Language traps: `==`/`===`,
mutable default args, `await` in `forEach`, floating promises, `== null`, `NaN`,
int/float, tz/encoding. Security: no hardcoded secret, no `eval`/`exec` or
SQL-string-concat on input, no unsafe HTML with untrusted data.

## 2. Reliability
No empty `catch`, no swallowed error, no silent fallback that hides a bug.
External calls (net/fs/db/subprocess) have error handling + timeouts/retries
where it matters. Resources released on every path (files, handles, sockets,
locks, listeners, subscriptions, timers). No new races; shared mutable state
guarded; idempotent ops stay idempotent. Inputs validated at the boundary.

## 3. Coverage
Behaviour-bearing changes have tests asserting real OUTCOMES and the edge
cases above — not "it runs", not a mirror of the impl, not a test that can't
fail. If the project has a suite, RUN it and make it pass. Add the missing
tests; delete tautological ones. **Linters at max**: run the project's
strictest checkers and confirm zero new findings — Biome
`biome check --error-on-warnings`, Semgrep `semgrep --config auto --error`,
Ruff `ruff check --select ALL`, ESLint `--max-warnings=0`. Whatever the repo
has configured; if `.scope.json` declared an acceptance, that's the bar.

## 4. Anti-slop
Apply ALL items in `~/.agents/hooks/anti-slop.md` (single source of truth —
not repeated here) to every hunk. Fix hits; consolidate clones. If the scanner
is available, run it scoped to the files listed above
(`python ~/.cursor/skills/anti-slop/scripts/scan_slop.py <files>`); NEVER use
`--all` at review time — that audits the entire pre-existing codebase, which
is out of scope here (axis 0) and not actionable in a bounded review. A
whole-codebase audit is a separate, deliberate manual task (`cursordoctrine
sweep`). Step B: if the header's Session footprint is >5 files or the request
was simple, justify each file or trim. Re-run tests; then stop.

## 5. Wiring completeness
Every user-visible change traces click → handler → call → store → render to a
REAL EFFECT (persist / mutate / call / render / notify). A dead end is slop
even if the code is clean: `handleSubmit` that doesn't persist, endpoint no
caller invokes, DB write nothing reads, component never mounted, hook/store
declared never consumed, `TODO`/empty body/`console.log` standing in for the
effect. Wire it now or remove the dead half. Later-stubs: `TODO(wire):`
naming what's missing.

## 6. Mechanics & stack integrity
Read the diff; fix by name (don't explain — delete and write the correct
pattern). N+1 (query in a loop → batch/join). Non-idempotent mutation on retry
(→ idempotency-key / txn). Multi-write without rollback (→ txn / Saga).
Unvalidated boundary input (→ Zod/Pydantic at the boundary). Zombie listener
(useEffect without cleanup `return`). God component (>150 lines). Tailwind soup
/ magic tokens / hardcoded hex / `z-[9999]`. Index-as-key in non-static lists.
Inline `Date.now()`/`Math.random()`/`process.env` in logic (→ inject). In-place
mutation of shared state (→ new structures). Arrow code >2 nesting (→ guard
clauses). Switch / 5+ if-else (→ Map dispatch). Mixed abstraction (SLAP).
Primitive obsession. Imperative `for` where `.map`/`.filter` work.
