FINAL REVIEW — you just finished an implementation. Before you treat it as done,
audit EVERYTHING you changed this session across the six axes below and FIX what
fails. Do NOT revert the behaviour the user asked for. If an axis is already
clean, say so in one line — do not manufacture work.

Start by re-reading the diff. Scope the review to your session's changes and the
code they touch.

## 0. Intent trace (HIGHEST PRIORITY — run first)
The hook extracted your last user message as "ORIGINAL REQUEST" above. For every
hunk in the diff, answer: which part of the request forced this change? Anything
that cannot trace to the request is a HALLUCINATED REQUIREMENT — a feature,
flag, refactor, abstraction, dependency, or "nice to have" that nobody asked for.
Revert each one. "Clean code, wrong feature" is the worst failure mode and no
later axis can catch it. This axis outranks all others. (If no ORIGINAL REQUEST
is present — sandboxed verify run, no transcript — skip this axis.)

## 1. Correctness
- The logic does what the task requires — no off-by-one, inverted condition,
  wrong operator, wrong return value, wrong import path.
- Edge cases the inputs imply: null / undefined / empty / zero / negative /
  boundary / very large. The happy path passing is not enough.
- Language traps: `==` vs `===`, mutable default args, `await` in `forEach`,
  floating promises, `== null`, `NaN` compares, integer/float, timezone/encoding.
- Security: no hardcoded secret, no `eval`/`exec` on input, no SQL string
  concatenation, no unsafe HTML with untrusted data.

## 2. Reliability
- Every failure path is handled — no empty `catch`, no swallowed error, no silent
  fallback that hides a bug. Errors surface or are handled deliberately.
- External calls (network / fs / db / subprocess) have error handling and, where
  it matters, timeouts and bounded retries — no unbounded waits.
- Resources are released on every path including errors: files, handles,
  sockets, locks, listeners, subscriptions, timers.
- No new race conditions; shared mutable state is guarded; operations that should
  be idempotent are.
- Inputs are validated at the boundary; the code degrades gracefully instead of
  crashing.

## 3. Coverage
- Every behaviour-bearing change has a test. New function / branch / edge case →
  add a test. If the project has a test suite, RUN it and make it pass.
- Tests assert real OUTCOMES and the edge cases above — not "it runs", not a
  mirror of the implementation, not a test that cannot fail.
- Add the missing tests; delete tautological ones.

## 4. Anti-slop
Axis 0 already caught intent drift. This axis catches code-shape and cost slop
across the whole session diff.

Step A — mechanical scan (if available):
  If `~/.cursor/skills/anti-slop/scripts/scan_slop.py` exists, run:
    python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all
  If it does NOT exist, skip Step A (not a failure; do not hunt for the file).

Step B — canonical checklist (always):
  Read `~/.agents/hooks/anti-slop.md` and apply ALL 13 items to every hunk you
  changed this session. That file is the single source of truth for slop
  detection — items 1–10 are structural/code, 11 is semantic contracts, 12 is
  operational slop (retries, await-in-loop, telemetry spam), 13 is change
  surface. Fix every hit; consolidate clones to one source of truth.

Step C — session footprint (also in the header above):
  If "Session footprint" shows >5 files or the request was simple, justify each
  file or trim. Unjustified files are slop.

Fix with edits now; re-run the scan (if Step A ran) and the tests; then stop.

## 5. Wiring completeness
For every user-visible behavior you added or changed (button, form submit, API
call, route, state transition, scheduled job), trace its execution path end to
end and confirm it reaches a REAL EFFECT (persist, mutate, call, render, notify).
A dead end is slop even if the code is clean. Hunt for the vibe-coding failure
mode where a layer EXISTS but is not WIRED:

  - `handleSubmit()` that does not persist / does not call the API.
  - An endpoint that no route or caller invokes.
  - A DB write / table that nothing reads or writes.
  - A component that renders but is never mounted / routed to.
  - A hook / store / context that is declared but never consumed.
  - A `TODO` / empty body / stubbed `console.log` standing in for the effect.

The bar is: a senior can follow the path click -> handler -> call -> store ->
render (or the equivalent slice) without hitting a gap. If a step is missing or
faked, either wire it now or remove the dead half so the diff does not ship
scaffolding that looks complete but does nothing. Stubs you intend to wire later
must be marked with a `TODO(wire):` comment naming what is missing; unmarked
dead ends are failures.
