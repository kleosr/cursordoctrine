ANTI-SLOP SELF-REVIEW — you just edited a file. Before you do anything else,
audit your own change against the checklist below. This is NOT the bug pass
(the self-review trigger covers security/correctness). This is about *slop*:
code that runs but should not ship.

For each item: if your edit is guilty, FIX IT NOW with Edit — delete the
abstraction, inline the duplicate, drop the dependency, remove the comment.
Do not explain, do not report, just fix. If the edit is clean, say nothing.

  1. EDGE CASES — Does it only handle the happy path? Check the null / empty /
     zero / boundary / error inputs the task implies. An unhandled obvious
     edge case is a bug waiting in production.

  2. DUPLICATION — Did you write logic that already exists in this repo? Look
     before you add. If it exists, call it; do not re-implement it.

  3. CONVENTIONS — Does it match the FILE's existing style, naming, structure,
     error-handling, and import patterns? Match the neighbours, not your
     defaults.

  4. DEPENDENCIES — Did you add a library for something the stdlib or an
     existing dependency already does? Remove it. A new dependency must earn
     its place.

  5. PREMATURE ABSTRACTION — Factory / Repository / Mediator / Strategy /
     Builder / base classes / interfaces / CQRS / Event Sourcing / DDD
     layering: is there a REAL, PRESENT problem — two or three concrete call
     sites that exist TODAY — that requires it? "For future flexibility" is
     not a reason. Delete it and write the direct code. Abstraction debt is
     layers without problems.

  6. ACCIDENTAL COMPLEXITY — Could a junior read this in 30 seconds? Extra
     indirection, generics, config, or layers that do not earn their keep →
     flatten them.

  7. TESTS — Do your tests assert real BEHAVIOUR and the edge cases, or do
     they just prove the code runs / mirror the implementation line-for-line?
     A test that cannot fail is slop. Make it verify outcomes.

  8. CARGO CULT — Can you state WHY each non-obvious construct is there? If you
     reproduced a pattern without the historical reason behind it, that reason
     may not hold here. Remove what you cannot justify. Replicating a shape you
     have seen is not the same as needing it.

  9. ARCHITECTURE — Does it respect the project's layering and boundaries — no
     reaching across layers, no business logic in the wrong place, no breaking
     a constraint the codebase clearly holds? Honour the constraints.

 10. REDUNDANT COMMENTS — Delete comments that restate the code
     ("// increment i", "# return the result"). Keep only comments that
     explain WHY, never WHAT.

Hard constraints: never revert the change the USER asked for — slop is the
stuff you added on top. Do not "improve" beyond removing slop. At most a few
targeted edits, then stop. The bar: would this pass a senior review at a top
engineering org without a single "why is this here?" comment.
