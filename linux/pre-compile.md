# Pre-compile — Thin Intent Compilation

ACTIVE EVERY IMPLEMENTATION TURN. Before writing or modifying a single line of
code, emit your Anchor Set. Compiling intent first is what stops the dilution
that no later axis can fully undo — a clean final review of the wrong feature
is still the wrong feature.

This is the proactive phase. The anti-slop checklist, the self-review trigger
and the final review are reactive — they audit after the fact. You compile the
intent BEFORE the first token of code so they have the right thing to audit.

## Step 0 — Restate the request (the user writes fast; you normalize)

Before the Anchor Set, in ONE line, play the request back as you understood it:

> **Understood as:** _one clean sentence — grammar fixed, pronouns resolved,
> implicit constraints made explicit, in the language of the request._

Mandatory every implementation turn. This line is the user's catch-point: a
misread surfaces HERE, before you write a line of code, instead of in review.
The restatement is **meaning-preserving** — you normalize phrasing, you do NOT
add scope, drop a constraint, or invent a requirement. If normalizing would
force a guess that changes what "correct" means, you do not bury the guess in
the restatement — you ask one sharp question (§5) and wait.

The user's verbatim words stay the ground truth: `.scope.json`'s `trace.query`
keeps them exactly as typed, and final-review traces every diff hunk back to
THAT, not to your paraphrase. Your normalized sentence becomes `intent` (and the
Anchor Set's OBJECTIVE below). The two must say the same thing in different
words — if you cannot make `intent` and `trace.query` agree, you have misread
the request, and that is the bug to fix first.

## The Anchor Set

Answer these four, terse, in your first response. One phrase each, not prose:

1. OBJECTIVE — your Step 0 restatement, tightened to the operational verb. One
   sentence, what is *strictly* necessary. Not "improve X" — "make X return Y
   when Z".
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

The contract is written for you **before your first token**: the `intent-precompile`
hook fires on `beforeSubmitPrompt` (right after the user hits send) and writes
`.scope.json` to the repo root with the real `intent` already locked from the
request — so the contract is the FIRST artifact of the turn, and you govern by it
from the very first action. `intent-anchor` then re-injects it on every tool
boundary to keep it in focus.
  - `intent` is locked from the request and REFRESHED when the request changes — a
    new prompt regenerates the contract and resets `files[]`, so it never carries
    over between features;
  - `files[]` is auto-recorded — the scope hook appends every file you edit, so
    you never maintain it by hand;
  - `acceptance` is SEEDED with a real default (never a bare `<TODO>`); it is not a
    blank you must fill, it is a draft you SHARPEN;
  - `trace.query` is the VERBATIM request (the audit anchor), `_intent_hash` and
    `_generated_by` are hook bookkeeping. Leave all three alone.

Your two targeted edits on the contract (each a string replace on ONE field, never
a whole-file rewrite), done as your FIRST actions this turn before editing source:
  - **`intent`** → replace the seed with your Step 0 restatement: the normalized,
    meaning-preserving sentence. This is what final-review axis 0 traces each diff
    hunk against, so a clean `intent` makes the audit sharp.
  - **`acceptance`** → sharpen the seeded default to the single deterministic check
    that decides done, which the hook cannot derive. The hook re-injects a loud
    demand every turn until you do.

Do **NOT** touch `trace.query`, `_intent_hash`, or `_generated_by`, and do **NOT**
rewrite the whole file: `_intent_hash` is computed from the verbatim `trace.query`,
not from `intent`, so refining `intent` is safe — but dropping the hash/trace
disables per-prompt regeneration and brings back cross-feature carryover. Keeping
`trace.query` verbatim is what lets the audit catch a paraphrase that quietly
changed the meaning: `intent` and `trace.query` must agree.

```json
{
  "intent":       "<YOU refine this: your normalized Step 0 restatement>",
  "files":        ["<auto-recorded by the hook as you edit>"],
  "acceptance":   "<seeded with a default; YOU sharpen to the deterministic check>",
  "allow_growth": false,
  "trace":        { "query": "<VERBATIM request - the hook owns this, leave it>", "ts": "<when>" },
  "_intent_hash": "<hook bookkeeping>",
  "_generated_by":"intent-precompile / intent-anchor hook"
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
