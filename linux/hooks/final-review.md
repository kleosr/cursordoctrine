Re-read the diff first; scope to your session's changes. Run the axes in order.
Untraceable or hallucinated work reverts; everything else gets fixed in place.
If an axis is clean, one line — don't manufacture work.

## 0. Intent trace (run first — outranks all)
Every diff hunk traces to the ORIGINAL REQUEST above. Anything that doesn't is
a HALLUCINATED REQUIREMENT — feature, flag, refactor, abstraction, dep, or
"nice to have" nobody asked for. Revert each. "Clean code, wrong feature" is
the worst failure; no later axis catches it. (No ORIGINAL REQUEST → sandboxed
run → skip.)

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
tests; delete tautological ones.

## 4. Anti-slop
Step A (if available): the review header carries the ANTI-SLOP SCAN block —
it is scoped to the files you changed this session (NOT `--all`). Fix the hits
on lines you added. NEVER run `--all` at review time: that audits the entire
pre-existing codebase, which is out of scope here (axis 0) and not actionable
in a bounded review — a whole-codebase audit is a separate, deliberate manual
task. If the header has no scan block, run
`python ~/.cursor/skills/anti-slop/scripts/scan_slop.py <the files listed
above>`; if the scanner is unavailable, skip (not a failure).
Step B (always): apply ALL items in `~/.agents/hooks/anti-slop.md` (single
source of truth — not repeated here) to every hunk. Fix hits; consolidate
clones. Step C: if the header's Session footprint is >5 files or the request
was simple, justify each file or trim. Re-run the scoped scan + tests; then
stop. (The per-edit `scope-gate-audit` hook already checks `.scope.json`
files[] — trust it; axis 0 is the whole-session backstop.)

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
