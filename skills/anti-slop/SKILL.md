---
name: anti-slop
description: >-
  Finds and deletes AI slop from a change OR a whole codebase — premature
  abstractions (Factory/Repository/Mediator/CQRS/Event-Sourcing/DDD), unnecessary
  dependencies, redundant comments, happy-path-only code, superficial tests /
  test theater, type escapes (as any / @ts-ignore / type: ignore), swallowed
  errors (empty catch, except: pass), prompt residue ("in a real app", banner
  comments, emoji in code), cargo-cult patterns, accidental complexity,
  hallucinated requirements (unrequested features / scope creep), framework
  slop (React useEffect hell, Astro hydration bloat, Tailwind class soup,
  SELECT *, ORM include pyramids, boolean traps, guard-chain defensive
  inflation, async wrapper mania), and CLONE PROLIFERATION / duplicate helpers
  (20 copies of isRecord, DRY violations,
  knowledge duplication) — organized as twelve failure classes, while preserving
  the behaviour the user actually asked for. Use when the user says remove AI
  slop, de-slop, clean up the slop, /anti-slop, "this is slop", review the whole
  codebase for slop, find duplicate or clone functions, or asks to strip
  over-engineering, premature abstraction, cargo cult, redundant comments, or
  duplicate utilities.
metadata:
  layer: active-cleanup
  pairs-with: declared-editing, semantic-density-audit
---

# Anti-Slop

Active counterpart to the `afterFileEdit` anti-slop **hook**. The hook only
*advises* after each edit; this skill does a deliberate sweep that **removes**
the slop. Same detectors — but here you fix, you don't flag.

Slop = code that runs but should not ship. Think in **failure classes**, not
individual smells — every finding belongs to one of twelve:

| Class | Signal | Names it goes by |
|-------|--------|------------------|
| **Structural** | More architecture than business logic. | Premature Abstraction/Generalization, Abstraction Debt, Overengineering, Architecture Astronautics, Indirection Hell, Wrapperitis, Layer Proliferation, Enterprise FizzBuzz |
| **Semantic** | Code works but no longer matches the problem. | Semantic/Requirement Drift, Intent Erosion, Spec Divergence, Hidden Assumptions |
| **Complexity** | Every change feels expensive. | Boilerplate Inflation, Complexity Creep, Configuration Sprawl, Cyclomatic Inflation, Cognitive Complexity |
| **Duplication** | One bug fix = five edits. | Copy-Paste Programming, Clone Proliferation, Knowledge/Logic Duplication, Divergent Duplication, Helper Hell, Micro-Abstraction Spam, Semantic Density Collapse, Generated-Code Fingerprints |
| **Dependency** | More package management than product. | Dependency Bloat/Hell, Ghost Dependencies, Transitive Explosion, Supply-Chain Bloat |
| **Testing** | 90% coverage, 0% confidence. | Test Theater, Snapshot Abuse, Mock Hell, Assertion Poverty, Coverage Worship |
| **Type-System** | The types exist but nobody trusts them. | Any-Driven Development, Stringly Typed Design, Type Erosion, Type Escapes, Unsafe Casting |
| **API** | Nobody knows how to use it correctly. | Leaky Abstractions, API Surface Inflation, Parameter Explosion, Boolean Trap |
| **State** | Bugs appear from unrelated changes. | Mutation Soup, Temporal Coupling, Hidden Side Effects, Shared Mutable State, State Explosion |
| **Performance** | Works in demos, collapses at scale. | N+1 Queries, Algorithmic Waste, Incidental Allocation, Render Thrashing, Cache Cargo-Culting |
| **Documentation** | Docs actively mislead. | Comment Debt, Documentation Drift, Generated Doc Noise, Stale Examples |
| **AI-Specific** | Looks professional; nobody can say why it exists. | Hallucinated Architecture/Dependencies/APIs, Defensive Code Inflation, Scaffold Explosion, Refactor Cascades, Synthetic Abstraction, Prompt Residue, Context Drift |

The governing question, asked of every survivor: **every new file, dependency,
abstraction, layer, pattern, interface, hook, provider, service, context,
middleware, migration, component, type, and configuration must justify its
existence with a measurable reduction in complexity elsewhere.** What cannot
answer is slop — most AI slop survives because nobody asks. The senior-review
form of the question: *what requirement forced this abstraction into
existence?* AI rarely has an answer.

## Framework failure modes (the vibe-coding stack)

Slop is framework-dependent — a React anti-pattern does not exist in SQL. The
classes above specialize per stack; *(scanner)* marks mechanically seeded ones:

- **TypeScript** — any leakage / `as unknown as` cascades *(scanner)*; fake
  type safety (types exist, runtime validation at boundaries doesn't);
  interface explosion (`UserDTO`/`UserResponseDTO`/`UserViewDTO` for one
  entity); generic abuse (`<T extends Record<string, any>>`) where plain types work.
- **React** — useEffect hell for state synchronization (compute it, or use the
  right primitive); derived state stored in useState instead of computed;
  prop-drilling chains; everything-in-Context; component fragmentation
  (`Button` + `ButtonIcon` + `ButtonLabel` + `ButtonWrapper` for no reason);
  hooks generating hooks.
- **Astro** — island explosion (50 where 3 are needed); `client:load`
  everywhere when `client:visible` / `client:idle` / zero JS would do; SSR for
  static content; the page that accidentally became a React SPA.
- **Node** — Controller/Service/Repository/Manager/Provider stacks for CRUD;
  pointless async wrappers (`await Promise.resolve`, async promise executors)
  *(scanner)*; 30-deep middleware chains; custom error hierarchies nobody
  catches; singletons as globals.
- **SQL / Postgres** — N+1 queries; `SELECT *` in checked-in SQL *(scanner)*;
  premature AND missing indexes (both are "nobody measured"); 20-table join
  monsters; JSONB as a schema escape hatch (`data JSONB` for everything);
  migration spam; schema drift from business reality.
- **Supabase** — RLS policies nobody can explain; trusting the client with
  security; RPC proliferation (hundreds of tiny functions); auth state
  duplicated outside supabase-js; storage permissions re-implemented in code.
- **Tailwind** — 200+ character class soup *(scanner)*; magic values
  (`w-[347px]`) *(scanner)*; the same class string pasted everywhere instead of
  one extracted primitive.
- **ORM (Prisma/Drizzle)** — `include` nested five levels deep; nobody reads
  the generated SQL; every relationship modeled twice; ORM worship that
  ignores what the database actually does.
- **API** — boolean traps (`createUser(true, false, true)`) *(scanner)*; god
  endpoints (`/api/data` does everything); more DTOs than entities; v1–v4 all
  alive forever.
- **AI-specific TS/React** — deepening guard chains (`if (!data) return; if
  (!data.user) return;` — the fix is `?.`) *(scanner)*; fallback hell
  (`a ?? b ?? c ?? ""` everywhere); scaffold explosion (hooks/ utils/ helpers/
  services/ providers/ adapters/ before any business logic exists);
  hallucinated extensibility (`UserFactory`/`UserRegistry`/`UserStrategy` for
  one user type).

## The one rule that outranks everything

**Never delete the behaviour the user asked for.** Slop is what got added *on
top* of the task — speculative layers, drive-by abstractions, filler. If
removing something would change what the feature does, it is not slop: leave it.
When unsure whether something is slop or intent, **leave it and say so** — never
guess-delete.

## Workflow

Track these phases (TodoWrite on Cursor, if available):

1. **Scope** — decide what to clean: the **whole codebase** (`--all` — the
   default for a "review/clean the codebase" request), a change in progress (the
   diff), or specific files the user named. State SCOPE in one line. Do not
   wander outside it.
2. **Scan** — get the deterministic inventory first. Pick the mode:
   ```
   python scripts/scan_slop.py --all --root .  # WHOLE codebase + duplication (recommended)
   python scripts/scan_slop.py --root .        # only a change in progress (diff vs HEAD)
   python scripts/scan_slop.py src/foo.ts ...  # specific files
   ```
   `--all` is the one that reviews the *entire current codebase* and runs the
   cross-file **duplication analysis** (clones / DRY — see below); it is what you
   want for "check what the codebase needs". Explicit paths audit only those files
   and **suppress dead-helper / single-use analysis** (reference counts need the
   whole tree). Diff mode is **silent on a clean tree** by design (nothing to vet).
   Use `python3` if that is your platform's launcher. Resolve `scripts/` against
   this skill's own directory. Add `--gate` to fail CI when slop is found (works
   with `--format json`; the size-only "substantial change" note never gates). If
   the script cannot run, do the detection by hand — it is only `git` plus the
   regexes below. The scanner is deliberately narrow (high precision): it seeds
   deterministic slop. Whether or not it finds anything, still walk the taxonomy
   — most slop is semantic and never shows up in a regex.
3. **Delete** — walk the taxonomy table below. For each hit: fix it, don't
   report it line-by-line.
4. **Verify** — re-run the scanner (expect clean), re-read the diff, confirm
   behaviour is unchanged and the diff got *smaller*. Then trace every remaining
   addition back to the user's request — anything you cannot trace is a
   hallucinated requirement: delete it or ask. Run the project's tests if
   behaviour-bearing code moved.
5. **Report** — short summary: what slop was removed, what was left and why.

## Taxonomy → fix action

Walk every row. Rows tagged *(scanner)* are seeded mechanically by
`scan_slop.py`; the rest need your judgement.

| Slop | How to spot it | Fix |
|------|----------------|-----|
| **Unnecessary dependency** *(scanner)* | new entry in package.json / requirements / pyproject / Cargo.toml / go.mod … | Remove it; use the stdlib or an existing dep. Keep only if it clearly earns its place. |
| **Premature abstraction / Abstraction Debt** *(scanner)* | new `*Factory` / `*Repository` / `*Mediator` / `*Strategy` / `*Builder` / `*Wrapper` / `*Orchestrator` / base class / interface, or CQRS / Event-Sourcing / DDD / Hexagonal layering with fewer than 2–3 real call sites *today* | Delete the layer; inline the direct code. "For future flexibility" is not a present problem. |
| **Redundant comments** *(scanner)* | a comment that restates the next line (`// increment i`, `# return the result`) | Delete it. Keep only comments that explain WHY. |
| **Type escapes** *(scanner)* | `as any`, `: any`, `@ts-ignore` / `@ts-nocheck`, `# type: ignore`, unsafe casts that silence the checker | Fix the type, not the checker. If a boundary is truly untypable, isolate ONE typed adapter instead of spraying `any`. |
| **Swallowed errors / Defensive inflation** *(scanner)* | empty `catch {}`, `.catch(() => {})`, bare/broad `except: pass`; try/catch wrapping that only hides failures | Let it fail loudly or handle it meaningfully. Delete catch-alls that exist to suppress. |
| **Happy-path only** | no handling for the null / empty / zero / boundary / error inputs the task implies | Add the missing edge-case handling. This is the one row where you ADD code. |
| **Hallucinated requirements** | features, options, config flags, endpoints, CLI args, or "nice to have" handling that no user message asked for and no existing code requires — walk the diff and trace every addition back to the request | Delete it. If you genuinely believe it's needed, ASK first — never ship unrequested scope. |
| **AI verbosity residue / Prompt residue** *(scanner)* | placeholder phrases (`in a real app`, `for production use`, `this is a simplified`, `TODO: implement actual`), emoji in code or log output, decorative banner walls (`// ===== HELPERS =====`), leftover debug prints | Delete on sight. None of these survive a human review. |
| **Duplicated logic** | new code mirrors something already in the repo | Delete the copy; call the existing function. Grep before you keep it. |
| **Clone proliferation / DRY / Knowledge duplication** | `--all` reports the same function name in ≥2 files, or identical bodies under different names (`isRecord` / `isObject` / `isPlainObject`) | Keep ONE canonical definition; re-point imports; delete the copies. One source of truth per concept. |
| **Utility explosion / Helper Hell / Fingerprints** | a swarm of tiny `is*` / `assert*` / `safe*` one-liners; fingerprints (`isRecord`, `safeParse`, `sleep`, `retry`, `assertNever`) | Inline single-use micro-helpers; consolidate genuinely shared ones into one module. |
| **Semantic opacity / low-density names** *(scanner)* | identifiers that exist but communicate no intent: `DataManager`, `CoreEngine`, `process()`, `handleThing`, `utils.ts`, `x1`, `tempFix`, `finalFinal`. FAIL = bare low-density token or generic-suffix class with no domain noun; WARN = defensible DDD with a domain noun (`PostgresUserRepository`). Shared denylist lives in `low_density.py` and fires identically in `scan_slop.py --all` and the per-edit `semantic-density-audit` hook. | Rename to state the concrete responsibility: `DataManager` → `InvoiceRepository` or `PersistUserSessions`; `process` → `GenerateMonthlyReport`; `utils.ts` → `invoice_totals.ts`. Leave WARNs that are intentional DDD. |
| **Ignored conventions** | style / naming / structure / error-handling differs from the file's neighbours | Rewrite to match the surrounding code. |
| **Accidental complexity** | indirection / generics / config a junior can't read in 30s | Flatten to the simplest form that works. |
| **Superficial tests / Test theater** | the test asserts "it runs", mirrors the implementation, or cannot fail; literal tautologies (`expect(true).toBe(true)`, `assert True`) *(scanner)*; snapshot-everything, mocks of mocks, assertion poverty | Rewrite to assert real outcomes and the edge cases; delete tautological tests. |
| **API slop** | boolean traps (`fn(true, false)`), 5+ positional params, internals leaking through signatures, three names for one concept | Options object / named params; collapse the surface; one name per concept. |
| **State slop** | shared mutable module state, side effects hidden in getters, order-dependent calls (temporal coupling) | Localize state, make effects explicit, inject dependencies. |
| **Performance slop** | queries/IO inside loops (N+1), per-call allocation in hot paths, speculative caches nobody measured | Move IO out of loops; measure before caching; delete speculative caches. |
| **Documentation drift** | comments/docs describing behavior the code no longer has; stale examples that do not run | Fix or delete. Wrong docs are worse than no docs. |
| **Cargo cult / Semantic Density** | a pattern copied without its reason; you cannot state WHY it is there | Remove what you cannot justify. A shape you have seen ≠ a shape you need. |
| **Architectural violation / drift** | reaches across layers, business logic in the wrong place, breaks a project constraint — or **drift**: new top-level dirs, modules, or structural patterns that did not exist before this session | Move it to the right layer or revert to the established pattern. Structure changes need explicit user intent, not model initiative. |

### Detection regexes (for scanning by hand — the scanner automates all of these)

- Premature abstraction: `\b(class|interface|struct|trait|protocol)\s+[A-Z]\w*(Factory|Repository|Mediator|Strategy|Singleton|Facade|Builder|Visitor|Decorator|Wrapper|Orchestrator)\b`, plus `\b(CQRS|Event[\s-]?Sourcing|Domain[\s-]?Driven|Aggregate Root|Bounded Context|Hexagonal Architecture|Onion Architecture)\b`.
- Redundant comment: a `//`, `#`, or `*` line that restates the adjacent code verb-for-verb.
- New dependency: an added line in a dependency manifest declaring `name → version` (manifest metadata like `"version":` / `"node":` is exempt).
- Verbosity residue: `\b(in a real (app|application|world|scenario)|for production use|this is a simplified|TODO:? implement actual|replace (this )?with your)\b` (case-insensitive); emoji in source (`[\u2600-\u27BF\U0001F300-\U0001FAFF]`); banner walls `^\s*(//|#|/\*)\s*[=*#]{5,}` (`# ----` dividers are a human convention, not residue).
- Type escapes: `as any`, `as unknown as`, `[,:<]\s*any\b`, `any[]`, `@ts-(ignore|nocheck)` (`@ts-expect-error` is the sanctioned form — leave it); Python `#\s*type:\s*ignore`.
- Swallowed errors: `catch {}` / `catch (e) {}` empty on one line, `.catch(() => {})` / `.catch(() => null)`, bare `except:` or `except Exception:` followed by `pass` (`except ImportError: pass` is a legitimate idiom). Multi-line catch blocks holding only a comment need your judgement.
- Tautological tests: `expect(<literal>).toBe(<same literal>)`, `assert True`, `assertTrue(true|True)`, `assert(true)`.
- Async wrappers: `await Promise.resolve(`, `new Promise(async`.
- Guard chains: consecutive `if (!x) return` lines where each test deepens the previous (`!data` → `!data.user`) — the fix is optional chaining.
- Boolean traps: two adjacent literal booleans in a call argument list (`fn(a, true, false)`); array literals exempt.
- SELECT star: `\bSELECT\s+\*` in `.sql` files (`--` comment lines exempt).
- Tailwind: `class=` / `className=` strings ≥200 chars; arbitrary values ≥100px (`w-[347px]`).
- Hallucinated requirements have no regex — they are the diff-vs-request comparison in Verify. Same for architecture drift: compare the tree/imports against what existed at session start (`git diff --stat`, new dirs). Semantic, State, API, and Performance slop are judgement rows: no regex can see intent drift or temporal coupling without lying about confidence.

### Review lens — score the survivors

When judging what the regexes cannot see, score against: **semantic density**
(business value per line), **change surface area** (files touched per simple
change), **traceability** (intent → implementation time), **locality**
(understandable without opening 20 files), **dependency cost**, **abstraction
ROI** (value created ÷ complexity introduced), **architectural compression**
(smallest architecture that solves the problem), **blast radius** (what one
change can break), **cognitive load**, **intent preservation** (implementation
vs requirements), **file proliferation** (files added per feature),
**abstraction pressure** (abstractions with fewer than two real
implementations), **indirection depth** (clicks to find the implementation),
**state count** (mutable states per feature), **hydration cost** (islands vs
actual interactivity), **SQL efficiency** (queries per page render). Code that
scores badly on two or more is slop even though no regex caught it.

## Duplication / clones (whole-codebase)

`scan_slop.py --all` runs a cross-file analysis a per-diff view cannot — the core
of a full-codebase de-slop:

- **Clone proliferation** — same function name in ≥2 files (the "20 copies of
  `isRecord`" problem).
- **Knowledge duplication** — identical bodies under different names
  (`isRecord` / `isObject`); one concept scattered, so one conceptual change
  becomes N edits (Divergent Change).
- **Generated-code fingerprints** — `isRecord`, `safeParse`, `sleep`, `retry`,
  `assertNever` recurring at statistically abnormal rates.
- **Micro-abstraction load** — the share of tiny `is*`/`assert*`/`safe*` helpers
  (Helper Hell / Semantic Density Collapse).

Fix: for each group pick ONE canonical definition (or inline a single-use
helper), re-point every import, delete the rest. Optimise for *knowledge
management*, not token volume — one source of truth per concept.

## Automatic final review

The `stop` hook (`~/.agents/hooks/final-review.ps1` on Windows,
`~/.agents/hooks/final-review.sh` on Linux) fires after the agent finishes an
implementation that edited files. It extracts the last `<user_query>` from the
session transcript (Tier 0 intent trace), reports session footprint (Tier 5),
and auto-submits a `followup_message` so the model audits six axes: intent,
correctness, reliability, coverage, anti-slop, wiring completeness. Axis 4 delegates to this skill's
scanner (`scan_slop.py --all`) and the canonical checklist at
`~/.agents/hooks/anti-slop.md` (13 items, including semantic contracts,
operational slop, and change surface). One bounded pass per implementation.

## Hard constraints

- Preserve requested behaviour (the rule above) — this outranks every fix.
- Smallest diff: removing slop should *shrink* the change, not reshape working
  code you never touched.
- Match the file's existing conventions whenever you rewrite.
- At most a couple of passes per file, then stop — don't thrash.
- This is a *quality* sweep, not a bug hunt. Correctness/security is the
  self-review trigger's job; don't duplicate it here.

## Report template

```
=== Anti-Slop Sweep ===
Scope: {diff | files}
Removed:
  - {N} premature abstraction(s): {names}
  - {N} unnecessary dependency(ies): {names}
  - {N} redundant comment(s)
  - {duplication inlined / tests hardened / edge cases added / complexity flattened}
Left (with reason): {intent-bearing items deliberately not touched}
Diff: {before} → {after} lines.   Tests: {pass | n/a}
```

## Cursor setup

| | |
|--|--|
| Install path | `~/.cursor/skills/anti-slop/` |
| Invoke | `/anti-slop`, or "remove the AI slop" |
| Scanner | `python scripts/scan_slop.py --all` |
| Final review | automatic via `stop` hook (`final-review.ps1` / `final-review.sh`) |
| Hook checklist | `~/.agents/hooks/anti-slop.md` (13 items; per-edit + final-review axis 4) |

The scanner is stdlib-only and needs Python 3.9+. Pairs with the **anti-slop
audit hook** (`anti-slop-audit.ps1` / `.sh`, advisory per edit), the
**semantic-density-audit hook** (`semantic-density-audit.ps1` / `.sh`, flags
low-density identifiers per edit — shares `low_density.py` with this scanner's
`semantic_density` bucket), the **scope-gate-audit hook**
(`scope-gate-audit.ps1` / `.sh`, Compuerta 1 — opt-in declared-scope gate
that flags edits outside `.scope.json`; shares `scope_match.py` with the
**stop hook** (`final-review.ps1` / `.sh`,
six-axis session review incl. intent trace and wiring completeness), and
**declared-editing** (YAGNI ultra ladder injected at session start).
This skill is the active "delete it now" layer those only nudge toward.
