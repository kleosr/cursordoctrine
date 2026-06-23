# Agent prompt: full cursordoctrine audit (Cursor hooks spec)

> Paste everything below the `---` line into a Cursor agent chat **in this repo**.
> This is a **read-only audit** unless the user explicitly asks you to fix findings.
> Official spec: https://cursor.com/docs/agent/hooks (fetched 2026-06-22).

---

You are auditing the **cursordoctrine** npm package — a user-level Cursor hook pack
installed to `~/.agents/hooks/` + `~/.cursor/` via `npx cursordoctrine install`.
Your job is to verify every file against the **Cursor hooks specification** and
hook-pack best practices **without recommending changes that would break the
designed hook chain or fail-open safety model**.

## Ground rules (non-negotiable)

1. **Read-only by default.** Report findings in a structured table. Do not edit
   files unless the user says "fix the audit findings."
2. **Preserve the hook chain.** These events form one pipeline — do not suggest
   collapsing, reordering, or removing steps without proving Cursor supports it:
   - `beforeSubmitPrompt` → `intent-precompile` (writes `.scope.json`)
   - `sessionStart` → `inject-doctrine` (governing text)
   - `afterFileEdit` → `scope-refresh` (record + stash; fires on ALL edits)
   - `postToolUse` → `scope-drain` (deliver stash as `additional_context`)
   - `beforeShellExecution` → `permission-gate` (deny list)
   - `stop` → `final-review` (`followup_message` + one-shot brake)
3. **Preserve fail-open semantics.** Script internal errors must exit `0` and
   allow the session to continue. Only `permission-gate` may emit
   `"permission":"deny"` for matched dangerous commands. Do **not** recommend
   `failClosed: true` on `beforeShellExecution` unless the user explicitly
   wants deny-on-timeout over availability (current design: `failClosed: false`).
4. **Preserve the stash-and-drain pattern.** Cursor does **not** consume
   `afterFileEdit` stdout for context injection. `scope-refresh` → file stash →
   `scope-drain` on `postToolUse` is intentional. Do not suggest replacing it
   with direct `afterFileEdit` output.
5. **hooks.json spec-clean.** Only documented keys per Cursor docs:
   `command`, `timeout`, `loop_limit`, `failClosed`, `matcher`, `type`.
   No invented fields.
6. **Cross-platform parity.** `linux/` (bash) and `windows/` (pwsh 7) must mirror
   behavior; platform differences are limited to shell/runtime mechanics.
7. **Verify after any fix:** `node bin/cli.mjs verify` (or `npx cursordoctrine verify`
   from an install). All checks must pass.

---

## Cursor hooks spec checklist (apply to every hook)

Source: https://cursor.com/docs/agent/hooks

| Rule | What to check |
|------|----------------|
| **version** | `hooks.json` has `"version": 1` |
| **stdin JSON** | Every command hook reads stdin; never blocks on unread stdin |
| **stdout JSON** | Valid JSON on stdout when emitting; `{}` when no-op |
| **exit codes** | `0` = success; `2` = block (only if intentionally used); other non-zero = fail-open unless `failClosed: true` |
| **Event output fields** | Only fields documented for that event (see table below) |
| **Matchers** | JavaScript-style regex, not POSIX (`^Write$` or omitted in JSON) |
| **timeout** | Set and reasonable (this pack: 5s except `stop` 30s) |
| **loop_limit** | Only on `stop` / `subagentStop`; this pack uses `3` on `stop` |
| **failClosed** | Explicit where set; matches script fail-open/fail-closed intent |
| **User hook paths** | Commands reference `~/.agents/hooks/*` and `~/.cursor/inject-doctrine.*`; Windows install must expand `~/` to real profile path |
| **Executable** | Linux `.sh` files executable after install (`chmod +x`) |

### Event → allowed output (must match implementation)

| Event | Script | Allowed output fields | This pack emits |
|-------|--------|----------------------|-----------------|
| `beforeSubmitPrompt` | intent-precompile | May block/rewrite prompt (spec); this pack **never blocks** | *(none — side-effect only)* |
| `sessionStart` | inject-doctrine | `additional_context` | `additional_context` |
| `afterFileEdit` | scope-refresh | *(spec: edit control; stdout not used for context here)* | *(none — stash file)* |
| `postToolUse` | scope-drain | `additional_context` | `additional_context` |
| `beforeShellExecution` | permission-gate | `permission`, `user_message`, `agent_message` | allow/deny JSON |
| `stop` | final-review | `followup_message` (only when `status === "completed"`) | `{}` or `followup_message` |

---

## File inventory — audit each path

Read every file below. For each, produce: **Status** (PASS / WARN / FAIL),
**Spec alignment**, **Parity** (linux vs windows if applicable), **Notes**.

### A. Hook wiring

| File | Audit focus |
|------|-------------|
| `linux/hooks.json` | All 6 events wired; timeouts; no matcher on afterFileEdit (fires on ALL edits); `failClosed: false` on beforeShellExecution; `loop_limit: 3` on stop; commands point to `~/.agents/hooks/` and `~/.cursor/inject-doctrine.sh` |
| `windows/hooks.json` | Same events/options as linux; `pwsh.exe -NoProfile -File` prefix; paths use expanded `$HOME` after install (template uses `~/`) |

### B. Shared helpers

| File | Audit focus |
|------|-------------|
| `linux/hooks/hook-common.sh` | `read_hook_stdin` BOM strip; jq/python3 fallback; `resolve_project_root` (cwd → workspace_roots → CURSOR_PROJECT_DIR → $PWD project-marker guard); `safe_conversation_id` transcript fallback; `extract_last_user_query` skips hook-generated turns + redacts secrets; `emit_json` ASCII-safe |
| `windows/hooks/hook-common.ps1` | Parity with bash helpers: `Read-HookStdin`, `Write-HookJson` pure-ASCII stdout, `Resolve-ProjectRoot` (project-marker fallback for non-git repos), `Get-SafeConversationId`, `Get-LastUserQuery`, `Redact-SecretsFromIntent`, `Expand-AgentPaths` |

### C. Hook scripts (pair audit linux + windows)

| Hook | Files | Audit focus |
|------|-------|-------------|
| **intent-precompile** | `intent-precompile.sh`, `.ps1` | Kill switches `HOOKS_ENFORCE`, `INTENT_PRECOMPILE_ENFORCE`; reads `prompt` from stdin; skips hook-generated prefixes (`FINAL REVIEW`, `SCOPE REMINDER`, etc.); no repo root → silent exit; writes `prompt` (hook-owned), seeds `intent = "[DRAFT] <prompt>"` on new/fresh; preserves agent `intent` + `files[]` + `acceptance` on continuation; `/new` or `new task:` resets scope and reseeds [DRAFT]; strips `_` metadata keys; never blocks |
| **inject-doctrine** | `../inject-doctrine.sh`, `../inject-doctrine.ps1` | Kill switch N/A; drains stdin; reads `doctrine.md` from install dir (`$HOME/.cursor/` when installed); emits `additional_context`; fail-open `{}`; ps1 ASCII-escapes non-ASCII; sh sources `$HOME/.agents/hooks/hook-common.sh` |
| **scope-refresh** | `scope-refresh.sh`, `.ps1` | Kill switches `HOOKS_ENFORCE`, `SCOPE_REFRESH_ENFORCE`; requires `.scope.json`; records edited path into `files[]` (dedup, never `.scope.json`); stashes reminder to `~/.cursor/.hooks-pending/scope-<cid>.txt`; silent without contract |
| **scope-drain** | `scope-drain.sh`, `.ps1` | One-shot: read stash, delete, emit `additional_context`; silent when no stash; shares kill switch with scope-refresh |
| **milestone-verify** | `milestone-verify.sh`, `.ps1` | Kill switches `HOOKS_ENFORCE`, `MILESTONE_VERIFY_ENFORCE`; requires `.scope.json` with non-empty `decomposition[]`; emits `VERIFY MILESTONE step N` when step's `expected_files` all touched; scrapes `ACCEPT/REVISE step N` from assistant transcript turns into `verifications[]`; silent on empty decomposition (YAGNI rung 1); (Linux) requires python3 |
| **intent-anchor** | `intent-anchor.sh`, `.ps1` | Kill switches `HOOKS_ENFORCE`, `INTENT_ANCHOR_ENFORCE`; re-fires when new files edited AND `intent` is empty/`[DRAFT]` OR `acceptance` is default seed; per-cid flag stores `files[]` count at last nudge; silent when no new files since last nudge; silent permanently once both fields filled |
| **permission-gate** | `permission-gate.sh`, `.ps1` | Kill switch `PERM_GATE_ENFORCE`; deny list parity (rm -rf absolute, fork bomb, curl\|sh, wget\|sh, git push --force, reset --hard, clean -f, dd/mkfs to devices, chmod/chown -R on /, npm/pnpm/yarn publish); anchored patterns avoid false positives (`git rm`, echo); internal error → allow; exit 0 always |
| **final-review** | `final-review.sh`, `.ps1` | Kill switches `HOOKS_ENFORCE`, `FINAL_REVIEW_ENFORCE`; only `status === completed`; `reviewed-<cid>.flag` verify-revise brake (stores changed-file count; re-reviews if diff changed, ends if same); 7-day stale sweep; git diff HEAD + untracked (falls back to `.scope.json` `files[]` for non-git projects); `.scope.json` declared vs touched diff; intent from scope then transcript; arms flag with count before emit; `loop_limit: 3`; `.md` REQUIRED (no stale fallback — emits install error if missing) |

### D. Prompt bodies (must stay in sync: linux/hooks/ mirrors windows/hooks/)

| File | Audit focus |
|------|-------------|
| `hooks/final-review.md` | Eight axes (0-7); structured bullet report with ACCEPT/REVISE verdict; intent trace rules; [DRAFT] detection; prior-turn work guard; `.scope.json` declared scope; scanner scoped not `--all` |
| `hooks/anti-slop.md` | 40-item checklist; pairs with `skills/anti-slop/scripts/scan_slop.py` |
| `hooks/cleanup-doctrine.md` | Whole-repo sweep doctrine for `cursordoctrine sweep` only; distinct from session final-review |

### E. Doctrine

| File | Audit focus |
|------|-------------|
| `linux/doctrine.md`, `windows/doctrine.md` | Identical content; ~80 lines; `.scope.json` contract matches intent-precompile + scope-refresh behavior; no contradiction with HOOKS.md |

### F. CLI installer

| File | Audit focus |
|------|-------------|
| `bin/cli.mjs` | `install` copies correct platform payload; merges (not overwrites) `~/.cursor/hooks.json`; reaps `STALE_HOOK_FILES`; `isStaleOurs` does not drop `inject-doctrine`; `verify` covers: JSON parse, path resolution, permission gate, intent-precompile create/preserve/skip, scope refresh/drain one-shot, final-review once/quiet; `sweep`/`uninstall` intact; Node >= 18, zero deps |
| `package.json` | `files` array ships all payloads; version matches changelog intent |

### G. Documentation

| File | Audit focus |
|------|-------------|
| `HOOKS.md` | Matches actual events (6 events, not "three hooks" if doc drift); kill switches complete (`INTENT_PRECOMPILE_ENFORCE`, `SCOPE_REFRESH_ENFORCE`); stash-drain explained; state paths under `~/.cursor/.hooks-pending/` |
| `README.md` | Install path, prerequisites (pwsh 7, jq/python3), verify command, session vs sweep; **flag** if "fail closed" wording contradicts permission-gate fail-open |
| `INSTALL.md` | Manual steps match cli.mjs behavior; merge instructions; verify payloads |

### H. Anti-slop skill

| File | Audit focus |
|------|-------------|
| `skills/anti-slop/SKILL.md` | Describes on-demand sweep; does not claim to replace hooks |
| `skills/anti-slop/scripts/scan_slop.py` | Runnable; used by `sweep`; no false coupling to session review `--all` |
| `skills/anti-slop/scripts/low_density.py` | Shared scorer for `scan_slop.py` `semantic_density` bucket; no separate per-edit wrapper |

---

## Hook-chain integrity tests (conceptual — confirm code matches)

Answer each yes/no with evidence (file:line or verify output):

1. **intent-precompile** does NOT overwrite `files[]` on a new user prompt when contract exists.
2. **intent-precompile** does NOT treat `FINAL REVIEW...` or `SCOPE REMINDER` as user intent.
3. **scope-refresh** writing `.scope.json` via shell does NOT re-trigger infinite `afterFileEdit` loop.
4. **scope-drain** deletes stash before emit so a crash cannot replay forever.
5. **final-review** second consecutive `stop` returns `{}` (brake cleared).
6. **final-review** on clean repo (no diff) returns `{}`.
7. **permission-gate** allows `git status`, denies `git push --force`.
8. **resolve_project_root** never falls back to bare `$HOME` (ghost `.scope.json` guard).
9. **inject-doctrine** missing file → `{}`, session still starts.
10. **Hook skip lists** (intent-precompile case prefixes vs `extract_last_user_query` HOOK_HDR regex) are in sync across sh/ps1/py.

Run: `node bin/cli.mjs verify` and attach pass/fail summary.

---

## Best-practice rubric (Cursor hooks + production shell)

Score each category PASS/WARN/FAIL:

| Category | Criteria |
|----------|----------|
| **Determinism** | Permission decisions and scope recording do not depend on LLM; prompt hooks not used where command hooks suffice |
| **Idempotency** | `install` re-runnable; merge preserves foreign hooks; stale hook reaper safe |
| **Observability** | Failures fail silently to user session (by design) — document where to debug (Hooks output channel) |
| **Security** | Deny list covers irreversible ops; secrets redacted in intent trace; no secrets in repo |
| **Portability** | Windows requires pwsh 7; Linux works with jq OR python3; git required for final-review |
| **Encoding** | JSON stdout safe under any console code page (ps1 ASCII escape, sh `ensure_ascii`) |
| **State hygiene** | State only under `~/.cursor/.hooks-pending/`; 7-day reap; never commit pending files |
| **Doc truth** | README/HOOKS/INSTALL agree on event count, kill switches, fail-open vs fail-closed |
| **Parity** | Every behavioral branch in `.sh` has equivalent in `.ps1` |
| **YAGNI** | No extra hooks, no prompt-hook overkill, no duplicate state machines |

---

## Explicit DO NOT RECOMMEND list

Flag as **process violation** if your audit would suggest any of these:

- Remove `scope-drain` and use `afterFileEdit` output for context injection
- Make `intent-precompile` block prompts or return `beforeSubmitPrompt` deny JSON
- Set global `failClosed: true` on `beforeShellExecution` without user opt-in
- Add undocumented `hooks.json` keys
- Move hooks to project `.cursor/hooks.json` (this pack is **user-level** by design)
- Replace git-based change detection in `final-review` with per-edit marker files
- Make hooks exit non-zero on parse errors (breaks fail-open guarantee)
- Add `preToolUse`/`subagentStop` hooks without a concrete gap (scope creep)
- Use POSIX regex in `hooks.json` matchers (`[[:space:]]`, etc.)
- Collapse linux/windows into one script (platform split is intentional)

---

## Output format (your response)

### 1. Executive summary
3–5 bullets: overall health, highest-risk finding, doc drift, parity gaps.

### 2. Spec compliance matrix
Table: Event | hooks.json | sh | ps1 | Cursor spec | Status

### 3. Findings table
| ID | Severity | File | Finding | Recommendation | Breaks chain? |
|----|----------|------|---------|----------------|---------------|
Use severity: **critical** (wrong spec / data loss / session break), **high** (parity / wrong deny), **medium** (doc drift), **low** (style).

### 4. Parity diff
List any behavioral difference between `linux/hooks/*.sh` and `windows/hooks/*.ps1`.

### 5. Documentation drift
List contradictions between README, HOOKS.md, INSTALL.md, and code.

### 6. verify output
Paste `node bin/cli.mjs verify` results (run it).

### 7. Fix plan (optional)
Only if user asked to fix: minimal diffs, one commit per logical change, re-run verify.

---

## Quick reference — installed layout after `npx cursordoctrine install`

```
~/.cursor/hooks.json          merged wiring
~/.cursor/doctrine.md         sessionStart payload source
~/.cursor/inject-doctrine.*   sessionStart command
~/.cursor/skills/anti-slop/   sweep skill
~/.agents/hooks/*.sh|ps1      hook scripts + *.md prompts
~/.cursor/.hooks-pending/     scope-*.txt, reviewed-*.flag (runtime, not in repo)
```

Repo source of truth: `linux/` or `windows/` + `bin/cli.mjs` + `skills/`.

Begin the audit now. Read all files in the inventory before writing findings.
