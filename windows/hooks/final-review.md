FINAL REVIEW — you just finished an implementation. Before you treat it as done,
audit EVERYTHING you changed this session across the five axes below and FIX what
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
- If `~/.cursor/skills/anti-slop/scripts/scan_slop.py` exists (INSTALL.md step 2
  copies it there), run the whole-codebase duplication scan:
    python ~/.cursor/skills/anti-slop/scripts/scan_slop.py --all
  If it does NOT exist, do not treat that as a failure and do not hunt for the
  file: apply the checklist in `~/.agents/hooks/anti-slop.md` to the session
  diff and look for duplicate function bodies in the files you touched.
- Either way, consolidate clones: same function in many files / identical bodies
  (the isRecord-class) → ONE shared definition, re-point imports, delete the
  copies.
- Premature abstraction (Factory / Repository / Mediator / CQRS / DDD with fewer
  than 2–3 real call sites), unnecessary dependencies, redundant restate-the-code
  comments, dead helpers, accidental complexity → remove.

Fix with edits now; re-run the scan and the tests; then stop.
