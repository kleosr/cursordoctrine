Re-read the diff first; scope to your session's changes. Run the axes in order.
Untraceable or hallucinated work reverts; everything else gets fixed in place.
If an axis is clean, one line — don't manufacture work.

## Report format (MANDATORY — emit this block EXACTLY, then stop)

Copy this template. Replace each verdict. One line per axis. No prose between lines.
For trivial diffs (1 file, <10 lines, typo/literal): collapse to axes 0+1 only,
mark the rest N/A.

    - **0 Intent trace**: PASS | FAIL — <one line>
    - **1 Correctness**: PASS | FAIL — <one line>
    - **2 Reliability**: PASS | FAIL | N/A — <one line>
    - **3 Coverage**: PASS | FAIL | N/A — <one line>
    - **4 Anti-slop**: PASS | FAIL — <one line>
    - **5 Wiring**: PASS | FAIL | N/A — <one line>
    - **6 Mechanics**: PASS | FAIL | N/A — <one line>
    - **7 Role-trace**: PASS | FAIL | SKIP — <one line>

    **Verdict**: ACCEPT | REVISE

Rules:
- **PASS** = axis is clean, no action needed.
- **FAIL** = a real issue exists. Fix it NOW, then the line becomes `PASS — fixed: <what>`.
- **N/A** = axis doesn't apply (e.g. no UI = wiring N/A, no tests exist = coverage N/A).
- **SKIP** = axis 7 only, when decomposition is empty (trivial one-liner).
- **ACCEPT** = all axes PASS, N/A, or SKIP. Stop immediately after the report.
- **REVISE** = any axis FAIL. Fix every FAIL, re-run tests, emit the report again
  with those lines now showing PASS. Then ACCEPT and stop.

No summary paragraph. No "in conclusion." No explanation unless an axis FAILs.

## 0. Intent trace (run FIRST — outranks all other axes)
"Clean code, wrong feature" is the worst failure; no later axis catches it.
- [ ] Every hunk traces to a sentence in ORIGINAL REQUEST. None → hallucinated → revert.
- [ ] Hunks from a prior turn (in working tree at turn start) → prior accepted work → leave.
- [ ] Touched but not in `.scope.json` `files[]` → scope creep IF added this turn → revert.
- [ ] Unsure if hunk is yours-this-turn → ASK, never auto-revert.
- [ ] No ORIGINAL REQUEST (sandboxed run) → skip this axis.
- [ ] `.scope.json` `intent` field is non-empty AND does NOT start with `[DRAFT]` AND reflects THIS turn's task. `[DRAFT]` or empty → rewrite it now (one-line restatement in your own words, remove the prefix).

## 1. Correctness
- [ ] Logic does what the task requires (re-read the request, not the diff).
- [ ] Edge cases: null / empty / zero / negative / boundary / very-large.
- [ ] Language traps: `==` vs `===`, mutable default args, `await` in `forEach`,
  floating promises, `== null`, `NaN`, int/float, tz/encoding.
- [ ] Security: no hardcoded secret, no `eval`/`exec`, no SQL-string-concat on
  input, no unsafe HTML with untrusted data.

## 2. Reliability
- [ ] No empty `catch`, no swallowed error, no silent fallback that hides a bug.
- [ ] External calls (net/fs/db/subprocess) have error handling + timeouts/retries.
- [ ] Resources released on every path (files, handles, sockets, locks, listeners, timers).
- [ ] No new races; shared mutable state guarded; idempotent ops stay idempotent.
- [ ] Inputs validated at the boundary (auth, parsing, untrusted sources).

## 3. Coverage
- [ ] Behaviour-bearing changes have tests asserting real OUTCOMES (not "it runs",
  not a mirror of impl, not a test that can't fail).
- [ ] RUN the suite if present; make it pass. Add missing; delete tautological.
- [ ] Linters at max, zero new findings: Biome `--error-on-warnings`, Semgrep
  `--config auto --error`, Ruff `--select ALL`, ESLint `--max-warnings=0`.
- [ ] `.scope.json` declared acceptance → that's the bar.

## 4. Anti-slop
- [ ] Apply ALL 40 items in `~/.agents/hooks/anti-slop.md` to every hunk (source of truth).
- [ ] If scanner available: `python ~/.cursor/skills/anti-slop/scripts/scan_slop.py <files>`.
- [ ] NEVER use `--all` at review time — audits pre-existing codebase, out of scope.
- [ ] Whole-codebase audit is separate (`cursordoctrine sweep`).
- [ ] Session footprint >5 files OR simple request → justify each file or trim.

## 5. Wiring completeness
- [ ] Every user-visible change traces click → handler → call → store → render → REAL EFFECT.
- [ ] No dead ends: `handleSubmit` that doesn't persist, endpoint no caller invokes,
  DB write nothing reads, component never mounted, hook declared never consumed.
- [ ] No placeholders standing in for effect: `TODO` / empty body / `console.log`.
- [ ] Wire it now OR remove the dead half. Later-stubs: `TODO(wire):` naming what's missing.

## 6. Mechanics & stack integrity
Fix by name (don't explain — delete and write the correct pattern).
- [ ] Data integrity: N+1 in loops → batch/join. Non-idempotent retry → idempotency-key. Multi-write → txn/Saga.
- [ ] Boundaries: unvalidated input → Zod/Pydantic at the boundary.
- [ ] React: zombie listener (useEffect without cleanup `return`). God component (>150 lines). Index-as-key in non-static lists.
- [ ] State: inline `Date.now()` / `Math.random()` / `process.env` in logic → inject. In-place mutation of shared state → new structures.
- [ ] Control flow: arrow code >2 nesting → guard clauses. Switch / 5+ if-else → Map dispatch. Mixed abstraction (SLAP).
- [ ] Styling: Tailwind soup / magic tokens / hardcoded hex / `z-[9999]`.
- [ ] Types: primitive obsession. Imperative `for` where `.map` / `.filter` work.

## 7. Role-trace (SKIP if decomposition is empty)
- [ ] Each `decomposition[i]` has a matching `verifications[i]` (else unfinished work — verify or remove the step).
- [ ] Each `verifications[i].verdict == "ACCEPT"` (open REVISE → fix or convert with one-line justification).
- [ ] No files touched this session outside any step's `expected_files` (else cross-step leakage — justify or revert).
- [ ] Empty decomposition (trivial one-liner, typo) → SKIP this axis. YAGNI rung 1 governs.
