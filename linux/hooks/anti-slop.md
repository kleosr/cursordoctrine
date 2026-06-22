ANTI-SLOP SELF-REVIEW — you just edited a file (or you are auditing the
session diff at final review). Code that runs but should not ship.

Intent trace (Tier 0 — hallucinated requirements, scope drift) runs FIRST at
stop via final-review axis 0, not here. This checklist covers code-shape and
cost slop. Apply every item; if guilty, FIX with Edit — delete, inline, drop.
Do not explain. If clean, say nothing.

  1. EDGE CASES — Happy path only? Check null / empty / zero / boundary / error
     inputs the task implies.

  2. DUPLICATION — Logic that already exists in this repo? **Search before
     claiming reuse** (Grep the codebase, don't assume). Call it; do not
     re-implement. Same function in many files (isRecord-class) → one source.

  3. CONVENTIONS — Match the FILE's style, naming, structure, error-handling,
     imports. Not your defaults.

  4. DEPENDENCIES — New library for something stdlib or an existing dep covers?
     Remove it. A dependency must earn its place.

  5. PREMATURE ABSTRACTION — Factory / Repository / Mediator / Strategy / Builder /
     CQRS / Event Sourcing / DDD: is there a REAL problem with 2–3 call sites
     TODAY? "Future flexibility" is not a reason. Delete and write direct code.

  6. ACCIDENTAL COMPLEXITY — Could a junior read this in 30 seconds? Flatten
     indirection, generics, config, layers that do not earn their keep.

  7. TESTS (epistemic slop) — Assert real OUTCOMES and edge cases, not "it runs",
     not a mirror of the implementation, not expect(true).toBe(true). A test
     that cannot fail is slop.

  8. CARGO CULT — Can you state WHY each non-obvious construct is there? Remove
     what you cannot justify. A shape you have seen ≠ a shape you need.

  9. ARCHITECTURE — Respect layering and boundaries. No reaching across layers,
     no business logic in the wrong place, no breaking project constraints.

 10. REDUNDANT COMMENTS — Delete comments that restate the code ("// increment
     i"). Keep only WHY, never WHAT. No prompt residue ("in a real app...").

 11. SEMANTIC CONTRACTS (Tier 1) — Did any existing function's BEHAVIOR change
     without its name, signature, or docstring changing? Names are contracts.
     deleteUser() that now soft-deletes is silent contract break.

 12. OPERATIONAL SLOP (Tier 3) — Retry loops without backoff/sleep/jitter?
     await fetch / ctx.db / prisma inside a for/while/map? Six or more
     console.log / print added in one edit? Token burn with no user value →
     remove or bound.

 13. CHANGE SURFACE (Tier 5) — Did a simple request touch many files? Every
     file in the diff must trace to the task. Trim unrelated hunks.

 14. MIXED LEVELS OF ABSTRACTION (SLAP violation) — Does one function mix a DB
     call, a string validation, and a date format? The model writes one blob
     because it cannot see the layers. Stop: SLAP - one function, one level of
     abstraction. Extract details to named helpers; the top function reads as a
     recipe, the bottom functions do the work.

 15. PHANTOM STATE (temporal coupling) — Must callers invoke init() before
     process()? Does the function break unless something else ran first? The
     model never validates lifecycle. Stop: make state explicit - a state
     machine, or a guard at the top of every public method that throws if the
     object is not in the required state. No implicit call-order contracts.

 16. PRIMITIVE OBSESSION — Are you passing loose strings/numbers for things
     that have rules (userId: string, email: string, amount: number)? The model
     spreads primitives instead of value objects. Stop: if a primitive has
     domain rules (validation, formatting, equality semantics), it is a named
     type / value object, not a raw string. Stop at the boundary where it enters.

 17. LOOP-DRIVEN LOGIC (imperative where declarative fits) — Are you writing
     for loops to transform arrays when the language has .map / .filter /
     .reduce / list comprehensions? The model defaults to imperative mutation.
     Stop: prefer pure higher-order functions for data transformation; reserve
     for-loops for genuine early-exit, index-based, or perf-critical paths.

 18. ARROW CODE (deep nesting / código flecha) — Nesting more than two if/for
     deep? The model nests because it cannot combine conditions, and the code
     drifts off to the right into an arrow. Stop: GUARD CLAUSES (early returns).
     If a condition fails, return immediately. The function reads top-to-bottom
     with no deep indents. Flatten anything nested beyond two levels.

 19. SYMPTOM MASKING (parcheo de síntomas) — Papering over the cause:
     `value ?? defaultValue` to hide a null that should never be null, or a
     silent try/catch that swallows the error so the system "does not crash".
     Stop: FAIL-FAST. A function that receives invalid state throws an explicit
     Error - never catch just to hide. Fix WHY the value is null; do not paper
     over it. A swallowed error is a deferred outage.

 20. BOOLEAN TRAP — A function takes a boolean to flip behavior
     (`processData(data, true)`). The model does this instead of two named
     functions. Stop: NO boolean behavior flags on public functions. If behavior
     diverges it is a distinct function, or a Strategy / enum. Callers must read
     what they get at the call site.

 21. SWITCH / IF-ELSE BLOAT — A giant switch or a long if/else-if chain of many
     cases. The model maps states this way instead of dispatching. Stop:
      DICTIONARY DISPATCH / MAP LOOKUP. A `Record<State, Handler>` (or Command
      pattern) replaces the switch - a new case is one table row, not a new branch.

 22. REACT MEMO/CALLBACK SLOP (Tier 6) — `useMemo` / `useCallback` added without
      a measured render-identity or expensive-computation reason. The model wraps
      everything in memo "for perf" when plain values and functions are correct.
      Stop: default to raw values. Memoize ONLY when (a) the value is the
      dependency of an effect or a child's identity check, AND (b) the
      computation or referential equality is provably costly. Delete memoization
      added to quiet performance anxiety.

 23. EFFECT SLOP (Tier 6) — `useEffect` that mirrors props into state, resets
      derived state after the fact, or handles events reactively. Stop: apply
      "You Might Not Need an Effect" — derive values during render, move event-
      caused work into event handlers, reset component state with the `key` prop
      instead of an effect. An effect that exists to keep two things in sync is
      the smell; the structure that needs syncing is the bug.

 24. DIFF CHURN — Unrelated renames, formatting, comment shuffling, or wrapper
      extractions that grow the diff without changing the design. The model
      tidies as it goes. Stop: the diff is proportional to the task. Revert
      churn. If a rename is genuinely needed, ship it in its own commit, not
      piggybacked on a behavior change.

 25. COMPATIBILITY CRUFT — Bolted-on flags, params, or branches that preserve
      accidental architecture instead of building the coherent end state. "The
      old code did this" is not a reason. Stop: if the only justification for a
      branch is backward compatibility with internal code you own, delete the
      branch and migrate the caller. A codebase that preserves every accidental
      shape accumulates cruft faster than it ships features.

 26. PARAMETER SPRAWL — A function with 4+ positional params, or boolean/flag
      params that switch behavior. The boundary is wrong: one function is doing
      several. Stop: split into named functions for each behavior, or accept an
      options object. `processData(data, true, false, true)` is the smell; the
      caller cannot read what it gets.

Hard constraints: never revert what the USER asked for — slop is what got added
on top. At most a few targeted edits, then stop.
