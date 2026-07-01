ANTI-SLOP SELF-REVIEW — thin intent compilation for the session diff.

Read the user's request as the source of truth. The scanner may catch some items;
judge the rest. A clean scan does not mean a clean diff.

OBJECTIVE: The diff is the smallest faithful change that satisfies the user's request.

CONSTRAINTS:
- No duplication: call existing helpers; do not re-implement.
- No premature abstraction (Factory/Repository/Mediator/Strategy/CQRS/DDD/Event Sourcing)
  without 2+ real call sites today.
- No dead code, dead parameters, or single-use helpers that should be inlined.
- No tautological tests; assert real outcomes.
- No type escapes (`any`, `@ts-ignore`, `# type: ignore`, etc.).

SCOPE:
- Only touch files that trace directly to the request.
- Never modify prior accepted work.

RISK:
- Do not add a dependency the stdlib or an already-installed dep can cover.
- Do not swallow errors or hide invalid state with silent defaults.
- Optional chaining (`?.`) is fine when absence is valid state; guard/throw when null is invalid.
- Do not leak secrets or inject/eval untrusted input.
- Do not write redundant comments, placeholder phrases, or AI residue.

Hard guardrails: never revert what the user asked for; prior accepted work stays;
if clean, say nothing.
