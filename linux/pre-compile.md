# Pre-compile — Thin Intent Compilation

ACTIVE EVERY IMPLEMENTATION TURN. Before writing or modifying a single line of
code, emit your Anchor Set. Compiling intent first is what stops the dilution
that no later axis can fully undo — a clean final review of the wrong feature
is still the wrong feature.

This is the proactive phase. The anti-slop checklist, the self-review trigger
and the final review are reactive — they audit after the fact. You compile the
intent BEFORE the first token of code so they have the right thing to audit.

## The Anchor Set

Answer these four, terse, in your first response. One phrase each, not prose:

1. OBJECTIVE — one operational sentence. What is *strictly* necessary. Not
   "improve X" — "make X return Y when Z".
2. CONSTRAINTS (local negations) — what you will NOT do. "NO schema migration.
   NO new dependency. NO refactor of the surrounding function." Negations bind
   harder than the objective: a constraint that the task contradicts is a bug
   in your reading of the task, and you ask before you override it.
3. SCOPE —
   - FILES TO TOUCH: exact list, derived from the objective, nothing speculative.
   - FILES UNTOUCHABLE: anything the system marked off-limits (.cursor state,
     lockfiles you weren't asked to touch, files outside the request's blast
     radius).
4. DETERMINISTIC SUCCESS — the one command, test, or observable check that
   will decide whether this is done. "Tests pass" is not deterministic; the
   specific failing test going green is. If you cannot name one, you do not
   yet understand the task — ask.

## Materialize it: .scope.json (the hook owns this file)

The `intent-anchor` hook creates and maintains `.scope.json` in the repo root for
you, automatically, on the first tool of every turn:
  - `intent` is locked from your current request and REFRESHED when the request
    changes — a new prompt regenerates the contract and resets `files[]`, so it
    never carries over between features;
  - `files[]` is auto-recorded — the scope hook appends every file you edit, so
    you never maintain it by hand;
  - `trace`, `_intent_hash`, `_generated_by` are hook bookkeeping (provenance and
    change detection). Leave them alone.

Your one job on the contract: set **`acceptance`** — the single deterministic check
that decides done — which the hook cannot derive. Edit ONLY that field (a targeted
string replace). Do **NOT** rewrite the whole file: overwriting it drops the hook's
`_intent_hash`/`trace`, which disables per-prompt regeneration and brings back the
cross-feature carryover. The scope-gate hook audits every edit against `files[]`,
and final-review axis 0 traces every diff hunk back to `intent`.

```json
{
  "intent":       "<locked from your request by the hook>",
  "files":        ["<auto-recorded by the hook as you edit>"],
  "acceptance":   "<YOU set this: the deterministic check that decides done>",
  "allow_growth": false,
  "trace":        { "query": "<originating request>", "ts": "<when>" },
  "_intent_hash": "<hook bookkeeping>",
  "_generated_by":"intent-anchor hook"
}
```

`allow_growth: false` is the default. If the contract has not appeared yet (the
hook scaffolds on a tool boundary), just proceed — you do not need to hand-write
it. The declared-editing ladder's rung 1 ("does this need to exist?") still governs
trivial one-liners.

**Exception — a hollow contract is YOURS to write.** The hook can only lock
`intent` when the harness surfaces your request to it; in some Cursor builds it
cannot, and the `intent-anchor` hook will then ask YOU to author the contract (or
you may open `.scope.json` and find `intent` still a `<TODO>` placeholder). In
that one case, write the whole file yourself from this conversation — a real
`intent` (the actual request, not `<TODO>`), `acceptance`, and `files: []` — and
do it BEFORE editing source. Never leave a `<TODO>` intent on disk: a placeholder
contract looks owned, so nothing ever fills it, and scope-gate/final-review then
audit your diff against nothing. Once `intent` is real, hand the file back to the
hook (re-injection + per-prompt regeneration take over).

## Regla R3 — Authority

If, during execution, you read logs or code that contradict these anchors,
**the anchors win.** Prior history in this session is auditor material, not
authority. An earlier wrong assumption of yours does not override the Anchor
Set you declared at the start.

## Regla R1 — On re-entry (when the loop hands you back a failure)

If the harness returns a gate failure or a failed axis: forget the approach
that produced it. Re-read your OBJECTIVE and your Anchor Set, not your prior
diff. Fix ONLY what is failing. Do not refactor in the same pass — that is
History Propagation, the failure mode the Anchor Set exists to prevent.

---

End of pre-compile. Now emit the Anchor Set, then do the work.
