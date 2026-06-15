ANTI-SLOP SELF-REVIEW — you just edited a file (or you are auditing the
session diff at final review). Code that runs but should not ship.

Intent trace (Tier 0 — hallucinated requirements, scope drift) runs FIRST at
stop via final-review axis 0, not here. This checklist covers code-shape and
cost slop. Apply every item; if guilty, FIX with Edit — delete, inline, drop.
Do not explain. If clean, say nothing.

  1. EDGE CASES — Happy path only? Check null / empty / zero / boundary / error
     inputs the task implies.

  2. DUPLICATION — Logic that already exists in this repo? Call it; do not
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

Hard constraints: never revert what the USER asked for — slop is what got added
on top. At most a few targeted edits, then stop.
