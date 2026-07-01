WHOLE-CODEBASE ANTI-SLOP SWEEP — you invoked `cursordoctrine sweep` to clean the
ENTIRE codebase, not just a session diff. This run EXPLICITLY authorizes fixing
pre-existing slop (the thing the bounded session final-review forbids). Scope
creep is the POINT here, under control.

Hard guardrail (do not violate even in a sweep): never change OBSERVABLE
BEHAVIOR the project depends on. Consolidating two clones is fine; silently
changing what a shared function returns is not. Prefer rename -> re-point
imports -> delete-copy. Run the typecheck/build/tests after each category; if
anything breaks, back the change out and flag it for manual review instead of
"fixing" the test.

Work category-by-category in this fixed order (cheapest, highest-precision
first — exact wins before judgement calls). After EACH category, re-run
`python <scanner> --all --root .` and confirm that category's findings are either
zero or every remaining finding carries a one-line WHY. If your fixes did not move
a non-zero count, stop that category — the scanner is the source of truth; do not
hand-wave a residual as "fixed".

  1. EXACT DUPLICATES (body_clones + name_clones): identical or
     same-named functions across files. Pick ONE canonical definition, re-point
     every import to it, delete the copies. One source of truth per concept.
  2. NEAR-DUPLICATES (near_clones): same shape, drifted names/values. Extract
     the shared part to a parameterized helper, OR confirm the drift is load-
     bearing and leave a one-line WHY comment. Do not merge clones whose
     differences are intentional.
  3. SINGLE-USE / DEAD HELPERS (single_use): inline into their one caller, then
     delete. Leave it if inlining would bury a meaningful named concept.
  4. SWALLOWED ERRORS: empty catch / broad except+pass. Either handle the error
     (log, propagate, degrade meaningfully) or, if the failure is genuinely
     benign in that spot, keep the catch but add a comment naming WHY it is
     safe to ignore. `try { rmSync(p, {force:true}) } catch {}` (best-effort
     cleanup of a temp file that may already be gone) is often a legitimate
     case — judge per call site, do not blanket-add logging.
  5. PREMATURE ABSTRACTIONS (abstractions): Factory/Repository/Strategy/Builder/
     CQRS/Event-Sourcing/DDD with <2 real call sites TODAY. Inline to direct
     code. Re-scan after — a removed abstraction sometimes dissolves a near-
     clone too.
  6. SEMANTIC OPACITY (semantic_density): low-density identifiers
     (DataManager, process(), utils.ts, Pt). Rename to state the concrete
     responsibility. Leave WARNs that are defensible DDD (a domain noun is
     present) unless the FAIL list is empty — WARN churn is low value. This
     goes LAST: renames touch many files and can collide with fixes above.
  7. GENERATED FINGERPRINTS + duplicate TYPES: consolidate as in (1).

After the last category: run `python <scanner> --all --root .` once more. The
expected end state is `slop_found: false` (or a documented residual you judged
load-bearing). Do NOT chase a clean scan by weakening real code — a WARN you
can justify with a domain noun is a correct "no".
