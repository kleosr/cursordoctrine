ANTI-SLOP SELF-REVIEW — code that runs but should not ship. Apply every item
to the session diff; if guilty, FIX with Edit — delete, inline, drop. Do not
explain. If clean, say nothing.

Items marked *(scanner)* are also caught mechanically by `scan_slop.py`; the
rest need your judgement. The scanner is high-precision / low-recall — a clean
scan does NOT mean clean code. Walk every item.

## Code shape

  1. EDGE CASES — Happy path only? Check null / empty / zero / boundary / error
     inputs the task implies.

  2. DUPLICATION *(scanner)* — Logic that already exists in this repo? **Search
     before claiming reuse** (Grep the codebase, don't assume). Call it; do not
     re-implement. Same function in many files (isRecord-class) → one source.

  3. CONVENTIONS — Match the FILE's style, naming, structure, error-handling,
     imports. Not your defaults.

  4. DEPENDENCIES *(scanner)* — New library for something stdlib or an existing
     dep covers? Remove it. A dependency must earn its place.

  5. PREMATURE ABSTRACTION *(scanner)* — Factory / Repository / Mediator /
     Strategy / Builder / CQRS / Event Sourcing / DDD: is there a REAL problem
     with 2–3 call sites TODAY? "Future flexibility" is not a reason. Delete
     and write direct code.

  6. ACCIDENTAL COMPLEXITY — Could a junior read this in 30 seconds? Flatten
     indirection, generics, config, layers that do not earn their keep.

  7. TESTS / TAUTOLOGIES *(scanner)* — Assert real OUTCOMES and edge cases, not
     "it runs", not a mirror of the implementation, not `expect(true).toBe(true)`.
     A test that cannot fail is slop.

  8. CARGO CULT — Can you state WHY each non-obvious construct is there? Remove
     what you cannot justify. A shape you have seen ≠ a shape you need.

  9. ARCHITECTURE — Respect layering and boundaries. No reaching across layers,
     no business logic in the wrong place, no breaking project constraints.

 10. REDUNDANT COMMENTS *(scanner)* — Delete comments that restate the code
     ("// increment i"). Keep only WHY, never WHAT.

 11. AI RESIDUE *(scanner)* — Placeholder phrases ("in a real app", "for
     production use", "TODO: implement actual"), banner walls (`// =====
     HELPERS =====`), emoji in code, leftover debug prints. Delete on sight.

## Type system

 12. TYPE ESCAPES *(scanner)* — `as any`, `: any`, `as unknown as`,
     `@ts-ignore`, `@ts-nocheck`, `# type: ignore`. The model silences the type
     checker instead of fixing the type. Stop: fix the type. If a boundary is
     truly untypable, isolate ONE typed adapter — not a spray of `any`. One
     `as any` is a deferred bug.

 13. SEMANTIC CONTRACTS — Did any existing function's BEHAVIOR change without
     its name, signature, or docstring changing? Names are contracts.
     `deleteUser()` that now soft-deletes is a silent contract break.

## Defensive inflation

 14. SYMPTOM MASKING *(scanner)* — `value ?? defaultValue` to hide a null that
     should never be null, or a silent `catch {}` that swallows the error so the
     system "does not crash". Stop: FAIL-FAST. Throw on invalid state; fix WHY
     the value is null. A swallowed error is a deferred outage.

 15. ARROW CODE — Nesting more than two if/for deep? The model nests because it
     cannot combine conditions. Stop: GUARD CLAUSES (early returns). If a
     condition fails, return immediately. Flatten anything nested beyond two
     levels.

 16. GUARD CHAINS *(scanner)* — Consecutive `if (!data) return; if (!data.user)
     return; if (!data.user.name) return;` — each test deepens the previous.
     Stop: optional chaining. `data?.user?.name` replaces the chain. One guard,
     not three.

## Operational slop

 17. OPERATIONAL SLOP — Retry loops without backoff/sleep/jitter? `await fetch`
     / `ctx.db` / `prisma` inside a `for`/`while`/`map`? Six or more
     `console.log` / `print` added in one edit? Token burn with no user value →
     remove or bound.

 18. ASYNC WRAPPERS *(scanner)* — `await Promise.resolve(...)`, `new Promise(
     async (resolve, reject) => ...)`. The model wraps things in async/await
     that don't need it, or constructs promises that swallow their own
     rejections. Stop: remove the wrapper. An async promise executor can never
     catch its own rejection.

 19. NON-IDEMPOTENT RETRY / MISSING ROLLBACK — A retry that double-charges on
     failure. A multi-write that leaves partial state when the second write
     fails. Stop: idempotency keys on mutations; transactions or sagas on
     multi-writes. "It usually works" is not a reliability strategy.

## API design

 20. BOOLEAN TRAP *(scanner)* — A function takes a boolean to flip behavior
     (`processData(data, true)`). Stop: NO boolean behavior flags on public
     functions. If behavior diverges it is a distinct function, or a Strategy /
     enum. Callers must read what they get at the call site.

 21. SWITCH / IF-ELSE BLOAT — A giant switch or a long if/else-if chain. Stop:
     DICTIONARY DISPATCH / MAP LOOKUP. A `Record<State, Handler>` replaces the
     switch — a new case is one table row, not a new branch.

 22. PARAMETER SPRAWL — A function with 4+ positional params, or boolean/flag
     params that switch behavior. The boundary is wrong. Stop: split into named
     functions, or accept an options object. `processData(data, true, false,
     true)` is the smell; the caller cannot read what it gets.

## State & data

 23. PHANTOM STATE (temporal coupling) — Must callers invoke `init()` before
     `process()`? Does the function break unless something else ran first? Stop:
     make state explicit — a state machine, or a guard that throws if not in the
     required state. No implicit call-order contracts.

 24. PRIMITIVE OBSESSION — Passing loose strings/numbers for things that have
     rules (`userId: string`, `email: string`, `amount: number`). Stop: if a
     primitive has domain rules, it is a named type / value object, not a raw
     string.

 25. UNVALIDATED BOUNDARY INPUT — Data from the user, network, or DB enters
     unvalidated. Stop: Zod / Pydantic / valibot at the boundary. The model
     trusts input by default; the boundary is where trust ends.

## React / Next.js

 26. MEMO/CALLBACK SLOP — `useMemo` / `useCallback` added without a measured
     render-identity or expensive-computation reason. The model wraps everything
     in memo "for perf" when plain values are correct. Stop: default to raw
     values. Memoize ONLY when the value is an effect dependency AND the
     computation is provably costly. Delete performance-anxiety memoization.

 27. EFFECT SLOP — `useEffect` that mirrors props into state, resets derived
     state after the fact, or handles events reactively. Stop: apply "You Might
     Not Need an Effect" — derive during render, move event-caused work into
     handlers, reset state with `key`. An effect that syncs two things is the
     smell; the structure that needs syncing is the bug.

 28. ZOMBIE LISTENERS — `useEffect` without a cleanup `return`. The model adds
     listeners, subscriptions, timers, or observers but never tears them down.
     Stop: every effect that registers something returns a cleanup function. A
     listener without cleanup is a memory leak and a stale-state bug.

 29. GOD COMPONENT — A component over 150 lines doing everything: fetching,
     state, transform, render. Stop: extract by responsibility — data hooks,
     transform utilities, presentational children. If you can't name what it
     DOES in one phrase, it's too big.

 30. INDEX AS KEY — `items.map((item, i) => <Li key={i} />)` in non-static
     lists. Stop: use a stable identity key. Index-as-key breaks reconciliation
     when items reorder, insert, or delete — silent state-attached-to-wrong-row
     bugs.

## CSS / SQL

 31. SELECT STAR *(scanner)* — `SELECT *` in checked-in SQL. The model writes it
     because it didn't check which columns the consumer needs. Stop: name the
     columns. `SELECT *` is a schema-coupling bomb — adding a column silently
     changes the result.

 32. TAILWIND SLOP *(scanner)* — 200+ character class strings pasted everywhere,
     magic arbitrary values (`w-[347px]`, `z-[9999]`), hardcoded hex instead of
     design tokens. Stop: extract repeated class clusters into a component or
     `@apply` utility. Use design tokens, not magic values.

## Structure & naming

 33. MIXED ABSTRACTION (SLAP) — One function mixes a DB call, a string
     validation, and a date format. Stop: one function, one level of
     abstraction. The top reads as a recipe; the bottom does the work.

 34. LOOP-DRIVEN LOGIC — Writing `for` loops to transform arrays when the
     language has `.map` / `.filter` / `.reduce` / comprehensions. Stop: prefer
     pure higher-order functions for data transformation; reserve `for` for
     genuine early-exit, index-based, or perf-critical paths.

 35. BARE RE-EXPORTS / BARREL INDIRECTION *(scanner)* — `export { foo } from
     './bar'` or `export *` — a file that ships nothing of its own. Directories
     containing only `index.ts`. Stop: import from the source. Delete barrels
     that don't consolidate real imports.

 36. SEMANTIC OPACITY *(scanner)* — Identifiers that exist but communicate no
     intent: `DataManager`, `process()`, `handleThing`, `utils.ts`, `CoreEngine`,
     `tempFix`. Stop: rename to state the concrete responsibility.
     `DataManager` → `InvoiceRepository`; `process` → `GenerateMonthlyReport`;
     `utils.ts` → `invoice_totals.ts`. If you cannot name what it DOES, you
     don't know what it IS.

## Process

 37. CHANGE SURFACE — Did a simple request touch many files? Every file in the
     diff must trace to the task. Trim unrelated hunks.

 38. DIFF CHURN — Unrelated renames, formatting, comment shuffling, or wrapper
     extractions that grow the diff without changing the design. Stop: the diff
     is proportional to the task. Revert churn. Ship renames in their own commit.

 39. COMPATIBILITY CRUFT — Bolted-on flags, params, or branches that preserve
     accidental architecture instead of building the coherent end state. "The
     old code did this" is not a reason. Stop: delete and migrate the caller.

 40. DELETION OVER ADDITION — Before you add a file, a function, a type, a
     param, a layer, or a dependency: can you DELETE something instead? The
     best code is the code never written; the second best is the code you
     removed. Boring over clever. Fewest files possible. If the diff is
     net-positive on a cleanup task, you brought more than you took — justify
     each addition or trim it.

---

Hard constraints: never revert what the USER asked for — slop is what got added
on top. Prior turns' accepted work stays (axis 0 of final-review distinguishes
yours-this-turn from prior). At most a few targeted edits, then stop.
