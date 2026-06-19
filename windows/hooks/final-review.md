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
  detection — it is NOT repeated here. Fix every hit; consolidate clones to one
  source of truth.

Step C — session footprint (also in the header above):
  If "Session footprint" shows >5 files or the request was simple, justify each
  file or trim. Unjustified files are slop.

Fix with edits now; re-run the scan (if Step A ran) and the tests; then stop.
(The per-edit `scope-gate-audit` hook already checks `.scope.json` files[] on
every edit — Step D of older versions ran that loop again here. Removed: it
duplicated the live hook and burned tokens. If `.scope.json` exists, trust the
per-edit gate; the intent trace in axis 0 is the whole-session backstop.)

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

## 6. Mechanics & Stack Integrity
Stateless, cheap mechanical checks. These are patterns the regex scanner CANNOT
catch (they need semantic/transversal judgement), so do them by reading the
diff. If a pattern below is present, FIX it — do not explain, delete and write
the correct pattern.

Backend / DB:
  - N+1 query: a query/fetch inside a loop over a list -> batch it or join.
  - Non-idempotent mutation: a POST/PUT that double-applies on retry -> make it
    idempotent (idempotency-key) or wrap in a transaction.
  - Transactional integrity: multi-write ops (DB/API/files) without rollback or
    a compensating action on partial failure -> wrap in a transaction or Saga.
  - Missing boundary validation: external input (API/params/DB/URL) trusted
    without a schema (Zod/Pydantic/Joi) -> validate at the boundary; never
    hand-validate deeper in the logic.

Frontend (React / Next / Astro / Tailwind):
  - Zombie listener: a useEffect that adds a listener/subscription/timer
    without a cleanup `return` -> add it.
  - God component: a single file doing fetch + state + business logic + JSX
    (>150 lines) -> split hooks / logic / render.
  - Tailwind soup & magic tokens: a className with >~6 utilities repeated across
    elements, or hardcoded hex / z-[9999] -> extract to a component or cva,
    use design tokens.
  - Index-as-key in non-static lists -> use a unique id.

Determinism / purity:
  - Date.now(), Math.random(), process.env read inline in business logic ->
    inject them (param or a context module) so the function is pure & testable.
  - In-place mutation of shared state (arr.push, obj.prop =) when a caller holds
    a reference -> return new structures ([...arr, x], .map/.filter).

Logic & structure:
  - Arrow code: >2 levels of nested if/for -> flatten with guard clauses
    (early returns). Code reads top-to-bottom, no deep indent.
  - Switch/if-else bloat: a switch or 5+ if/else branches -> Map/dispatch
    (Record<State, fn>) or the Command pattern.
  - Mixed abstraction (SLAP): a function mixing DB calls + string validation +
    date formatting -> one level of abstraction per function; extract helpers.
  - Primitive obsession: a primitive with business rules (email, userId, chainId)
    passed as a bare string/number across functions -> a named type/value object.
  - Imperative transforms: a `for` loop building an array when the language has
    .map/.filter/.reduce -> use the declarative form; reserve `for` for cases
    map/reduce cannot express.

You do NOT need to run a tool for these — read the diff and apply the named fix.
If none apply, say so in one line.
