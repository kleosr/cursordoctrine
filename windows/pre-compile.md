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

## Materialize it: .scope.json

Write the Anchor Set to `.scope.json` in the repo root before editing source.
This is the machine-checkable form — the scope-gate hook audits every edit
against `files[]`, and the final-review axis 0 traces every diff hunk back to
`intent`. An Anchor Set that lives only in your head is not an Anchor Set.

```json
{
  "intent": "<OBJECTIVE>",
  "files": ["<FILES TO TOUCH, repo-relative, glob-friendly>"],
  "acceptance": "<DETERMINISTIC SUCCESS>",
  "allow_growth": false
}
```

`allow_growth: false` is the default — the gate fires on any edit outside
`files[]`. Set it true only if you expect the work to discover new files
(a refactor, a migration) and you will justify each one as it appears.

No need to write `.scope.json` for trivial one-liners (a typo, a literal).
The declared-editing ladder's rung 1 ("does this need to exist?") governs when
the Anchor Set itself is overkill. When in doubt, write it.

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
