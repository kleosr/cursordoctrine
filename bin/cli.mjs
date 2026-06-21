#!/usr/bin/env node
// cursordoctrine — one-command installer for the cursordoctrine hook pack.
//
// The payload ships inside this npm package (windows/, linux/, skills/).
// `install` copies it into $HOME exactly the way INSTALL.md step 2 does,
// merging ~/.cursor/hooks.json instead of overwriting it. `verify` smoke-tests
// every hook with fake payloads (INSTALL.md step 3). `uninstall` removes our
// files and strips our hooks.json entries while preserving foreign ones.
//
// Zero runtime dependencies. Node >= 18.

import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const pkgRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(join(pkgRoot, 'package.json'), 'utf8'));

// CURSORDOCTRINE_HOME lets tests install into a sandbox home.
const HOME = process.env.CURSORDOCTRINE_HOME || homedir();
const platform = process.platform === 'win32' ? 'windows' : 'linux';
const payload = join(pkgRoot, platform);

const hooksDst = join(HOME, '.agents', 'hooks');
const cursorDst = join(HOME, '.cursor');
const skillSrc = join(pkgRoot, 'skills', 'anti-slop');
const skillDst = join(cursorDst, 'skills', 'anti-slop');
const pendingDir = join(cursorDst, '.hooks-pending');
const hooksJsonDst = join(cursorDst, 'hooks.json');

const injectName = platform === 'windows' ? 'inject-doctrine.ps1' : 'inject-doctrine.sh';
const doctrineFiles = [injectName, 'doctrine.md', 'USER-RULES.md', 'declared-editing.md', 'pre-compile.md'];

function payloadHookFiles() {
  return readdirSync(join(payload, 'hooks'));
}

// An entry in hooks.json is "ours" when its command references one of the
// script filenames we ship (hook scripts or the inject-doctrine script).
function ourKeys() {
  return [...payloadHookFiles().filter((f) => !f.endsWith('.md')), injectName];
}

function isOurs(command, keys) {
  return typeof command === 'string' && keys.some((k) => command.includes(k));
}

function keyOf(command, keys) {
  if (typeof command !== 'string') return undefined;
  return keys.find((k) => command.includes(k));
}

// Detect a STALE entry from a prior install: its command names a hook script
// (ps1/sh, not an .md prompt) under .agents/hooks OR names inject-doctrine,
// but that filename is NOT in the current payload. These are NOT foreign
// entries the user added — they are leftovers from an older version of THIS
// pack (e.g. anchor-set-nudge / minimal-edit-audit, deleted in 0.5.0). The
// old merge preserved them as "foreign", so deleted hooks kept running on
// every edit silently. Returning true here makes install reap them.
const HOOK_FILENAME_RE = /([\w.\-]+)\.(ps1|sh)\b/;
const INJECT_RE = /\binject-doctrine\.(ps1|sh)\b/;
function isStaleOurs(command) {
  if (typeof command !== 'string') return false;
  const hookMatch = command.match(HOOK_FILENAME_RE);
  if (hookMatch) {
    const fname = `${hookMatch[1]}.${hookMatch[2]}`;
    // If the script still ships, it's current ours (handled elsewhere).
    // payloadHookFiles() lists hooks/; doctrineFiles lists the parent-dir
    // payloads (inject-doctrine.*, doctrine.md, ...). We must check BOTH,
    // otherwise the sessionStart entry (inject-doctrine.ps1, shipped under
    // the parent dir, not hooks/) is misclassified as stale and dropped
    // from the merge — leaving the user with `"sessionStart": []` and no
    // doctrine injection at session start.
    return !payloadHookFiles().includes(fname) && !doctrineFiles.includes(fname);
  }
  if (INJECT_RE.test(command)) {
    return !doctrineFiles.includes(injectName) ? true : false;
  }
  return false;
}

function mergeHooks(existing, incoming, keys) {
  const out = structuredClone(existing);
  if (out.version === undefined) out.version = incoming.version;
  if (!out.hooks || typeof out.hooks !== 'object' || Array.isArray(out.hooks)) out.hooks = {};
  for (const [event, entries] of Object.entries(incoming.hooks || {})) {
    if (!Array.isArray(out.hooks[event])) out.hooks[event] = [];
    const cur = out.hooks[event];
    for (const entry of entries) {
      const k = keyOf(entry.command, keys);
      const i = cur.findIndex((x) => x && keyOf(x.command, keys) === k && k !== undefined);
      if (i >= 0) cur[i] = entry;
      else cur.push(entry);
    }
    // Reap stale ours entries from prior installs BEFORE treating anything as
    // foreign. isStaleOurs catches commands referencing scripts this pack no
    // longer ships (e.g. anchor-set-nudge / minimal-edit-audit, deleted in
    // 0.5.0). Without this, deleted hooks kept running silently on every edit
    // because the merge mistook them for user-added foreign entries.
    const live = cur.filter((x) => x && !isStaleOurs(x.command));
    const foreign = live.filter((x) => x && !isOurs(x.command, keys));
    const reordered = [];
    const used = new Set();
    for (const entry of entries) {
      const k = keyOf(entry.command, keys);
      if (!k || !isOurs(entry.command, keys)) continue;
      const found = live.find((x) => x && keyOf(x.command, keys) === k);
      if (found) {
        reordered.push(found);
        used.add(k);
      }
    }
    for (const x of live) {
      const k = keyOf(x?.command, keys);
      if (isOurs(x?.command, keys) && k && !used.has(k)) reordered.push(x);
    }
    out.hooks[event] = [...reordered, ...foreign];
  }
  let preserved = 0;
  for (const entries of Object.values(out.hooks)) {
    if (Array.isArray(entries)) preserved += entries.filter((x) => !isOurs(x?.command, keys)).length;
  }
  return { merged: out, preserved };
}

function install() {
  console.log(`cursordoctrine ${pkg.version} — installing the ${platform} hook pack into ${HOME}`);
  if (process.platform === 'darwin') {
    console.log('  note: macOS detected — installing the Linux (bash) hook pack.');
  }
  if (platform === 'windows' && HOME.includes(' ')) {
    console.log('  warning: home path contains spaces; hooks.json commands may need manual quoting.');
  }

  mkdirSync(hooksDst, { recursive: true });
  mkdirSync(cursorDst, { recursive: true });

  const hookFiles = payloadHookFiles();
  for (const f of hookFiles) cpSync(join(payload, 'hooks', f), join(hooksDst, f));

  for (const f of doctrineFiles) cpSync(join(payload, f), join(cursorDst, f));

  if (platform === 'linux') {
    for (const f of hookFiles) {
      if (f.endsWith('.sh')) chmodSync(join(hooksDst, f), 0o755);
    }
    chmodSync(join(cursorDst, injectName), 0o755);
  }

  // hooks.json: pwsh -File does not expand ~, so substitute the real profile
  // path (forward slashes) on Windows — same as INSTALL.md. Bash expands ~.
  let text = readFileSync(join(payload, 'hooks.json'), 'utf8');
  if (platform === 'windows') {
    text = text.replaceAll('~/', HOME.replaceAll('\\', '/') + '/');
  }
  const incoming = JSON.parse(text);
  const keys = ourKeys();

  let hooksJsonNote = 'written';
  let result = incoming;
  if (existsSync(hooksJsonDst)) {
    let existing = null;
    try {
      existing = JSON.parse(readFileSync(hooksJsonDst, 'utf8'));
    } catch {
      const bak = `${hooksJsonDst}.bak-${Date.now()}`;
      cpSync(hooksJsonDst, bak);
      hooksJsonNote = `existing file was invalid JSON — backed up to ${bak}, wrote fresh`;
    }
    if (existing) {
      const { merged, preserved } = mergeHooks(existing, incoming, keys);
      result = merged;
      hooksJsonNote = preserved > 0 ? `merged (${preserved} foreign entr${preserved === 1 ? 'y' : 'ies'} preserved)` : 'merged';
    }
  }
  writeFileSync(hooksJsonDst, JSON.stringify(result, null, 2) + '\n');

  rmSync(skillDst, { recursive: true, force: true });
  cpSync(skillSrc, skillDst, {
    recursive: true,
    filter: (src) => !src.includes('__pycache__'),
  });

  console.log('');
  console.log(`  ~/.agents/hooks        ${hookFiles.length} files`);
  console.log(`  ~/.cursor              ${doctrineFiles.join(', ')}`);
  console.log(`  ~/.cursor/hooks.json   ${hooksJsonNote}`);
  console.log('  ~/.cursor/skills       anti-slop (SKILL.md + scanner)');
  console.log('');

  const missing = prereqProblems();
  for (const m of missing) console.log(`  warning: ${m}`);
  if (missing.length) console.log('');

  console.log('Done. Restart Cursor — hooks.json is read at startup.');
  console.log('Next: npx cursordoctrine verify');
}

function prereqProblems() {
  const problems = [];
  if (platform === 'windows') {
    if (!canRun('pwsh.exe', ['-NoProfile', '-Command', 'exit 0'])) {
      problems.push('PowerShell 7 (pwsh) not found on PATH — the hooks will not run until it is installed.');
    }
  } else {
    if (!canRun('bash', ['-c', 'exit 0'])) {
      problems.push('bash not found — the hooks will not run until it is installed.');
    }
    if (!canRun('jq', ['--version']) && !canRun('python3', ['-c', ''])) {
      problems.push('neither jq nor python3 found — install one (the hooks prefer jq).');
    }
  }
  if (!pythonCmd()) {
    problems.push('Python 3.9+ not found — the anti-slop scanner is unavailable (the final review falls back to the checklist).');
  }
  return problems;
}

function canRun(cmd, args) {
  const r = spawnSync(cmd, args, { timeout: 15000, windowsHide: true, stdio: 'ignore' });
  return !r.error && r.status === 0;
}

function pythonCmd() {
  for (const c of platform === 'windows' ? ['python', 'python3', 'py'] : ['python3', 'python']) {
    if (canRun(c, ['-c', ''])) return c;
  }
  return undefined;
}

function runHook(file, payloadObj) {
  const cmd = platform === 'windows' ? ['pwsh.exe', '-NoProfile', '-File', file] : ['bash', file];
  const r = spawnSync(cmd[0], cmd.slice(1), {
    input: JSON.stringify(payloadObj),
    encoding: 'utf8',
    timeout: 20000,
    windowsHide: true,
    // Hooks resolve state under $HOME; pin it (and USERPROFILE, which pwsh
    // derives $HOME from) so sandboxed verify runs stay self-contained.
    env: { ...process.env, HOME, USERPROFILE: HOME },
  });
  if (r.error) return `spawn error: ${r.error.message}`;
  return `${r.stdout || ''}${r.stderr || ''}`.trim();
}

function verify() {
  console.log(`cursordoctrine ${pkg.version} — verifying the ${platform} hook pack in ${HOME}`);
  console.log('');

  if (!existsSync(hooksDst) || !existsSync(hooksJsonDst)) {
    console.error('Not installed (missing ~/.agents/hooks or ~/.cursor/hooks.json).');
    console.error('Run: npx cursordoctrine install');
    process.exit(1);
  }

  const ext = platform === 'windows' ? 'ps1' : 'sh';
  const hook = (name) => join(hooksDst, `${name}.${ext}`);
  const results = [];
  const check = (name, fn) => {
    let ok = false;
    let detail = '';
    try {
      const r = fn();
      ok = r === true || (typeof r === 'object' && r.ok);
      detail = typeof r === 'object' && r.detail ? r.detail : '';
    } catch (e) {
      detail = e.message;
    }
    results.push({ name, ok, detail });
    console.log(`  ${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  };

  check('hooks.json parses as JSON', () => {
    JSON.parse(readFileSync(hooksJsonDst, 'utf8'));
    return true;
  });

  // Validate that every command in hooks.json points at a file that actually
  // exists in $HOME. This is the check that catches a broken install template
  // (e.g. a hardcoded dev path, or a ~/ that did not get substituted) BEFORE the
  // user restarts Cursor and discovers every hook silently failed to load. The
  // direct-invocation checks below bypass hooks.json entirely, so without this
  // gate they would give green on an install Cursor cannot use.
  check('hooks.json command paths all resolve under $HOME', () => {
    const cfg = JSON.parse(readFileSync(hooksJsonDst, 'utf8'));
    const homeFwd = HOME.replaceAll('\\', '/');
    const missing = [];
    for (const entries of Object.values(cfg.hooks || {})) {
      if (!Array.isArray(entries)) continue;
      for (const e of entries) {
        const cmd = e && typeof e.command === 'string' ? e.command : '';
        if (!cmd) continue;
        // Pull the script path out of the command line. Windows: -File <path>;
        // Linux: bash <path>. Then expand ~ and resolve against $HOME.
        let path = '';
        const mF = cmd.match(/-File\s+([^\s]+)/);
        if (mF) path = mF[1];
        if (!path) {
          const mB = cmd.match(/(?:^|\s)bash\s+([^\s]+)/);
          if (mB) path = mB[1];
        }
        if (!path) continue;
        if (path.startsWith('~/')) path = homeFwd + path.slice(1);
        // Normalize to absolute with forward slashes for the existence check.
        const abs = path.includes(':') || path.startsWith('/')
          ? path
          : homeFwd + '/' + path;
        if (!existsSync(abs)) missing.push(`${path} (from: ${cmd.slice(0, 80)})`);
      }
    }
    if (missing.length) {
      return { ok: false, detail: `${missing.length} path(s) missing: ${missing.slice(0, 3).join('; ')}${missing.length > 3 ? ` (+${missing.length - 3} more)` : ''}` };
    }
    return true;
  });

  check('permission gate denies `git push --force`', () =>
    /"permission"\s*:\s*"deny"/.test(runHook(hook('permission-gate'), { command: 'git push --force' })));

  check('permission gate allows `git status`', () =>
    /"permission"\s*:\s*"allow"/.test(runHook(hook('permission-gate'), { command: 'git status' })));

  check('self-review trigger stashes + post-tool-use drains', () => {
    runHook(hook('self-review-trigger'), { conversation_id: 'npxv1', file_path: join(HOME, 'x.py') });
    return runHook(hook('post-tool-use'), { conversation_id: 'npxv1' }).includes('additional_context');
  });

  check('final review fires once, then goes quiet', () => {
    runHook(hook('self-review-trigger'), { conversation_id: 'npxv1', file_path: join(HOME, 'x.py') });
    const first = runHook(hook('final-review'), { conversation_id: 'npxv1', status: 'completed' });
    const second = runHook(hook('final-review'), { conversation_id: 'npxv1', status: 'completed' });
    if (!first.includes('followup_message')) return { ok: false, detail: 'no followup_message on first stop' };
    if (second.includes('followup_message')) return { ok: false, detail: 'review re-fired on second stop' };
    return true;
  });

  check('subagent review fires once, then goes quiet', () => {
    runHook(hook('self-review-trigger'), { conversation_id: 'npxv2', file_path: join(HOME, 'x.py') });
    const first = runHook(hook('subagent-stop-review'), { conversation_id: 'npxv2', status: 'completed' });
    const second = runHook(hook('subagent-stop-review'), { conversation_id: 'npxv2', status: 'completed' });
    if (!first.includes('SUBAGENT FINAL REVIEW')) return { ok: false, detail: 'no SUBAGENT FINAL REVIEW on first stop' };
    if (second.includes('followup_message')) return { ok: false, detail: 'review re-fired on second stop' };
    return true;
  });

  check('intent-anchor scaffolds .scope.json per-prompt, never to $HOME', () => {
    // The user-requested behavior: every NEW prompt -> a fresh .scope.json
    // in the repo root, intent locked from the query. Same prompt -> re-inject
    // without rewriting. Never writes to $HOME (the 0.4.4 ghost-file bug).
    // We drive it with a synthetic transcript so Get-LastUserQuery can read
    // the <user_query>; the hook resolves cwd -> HOME (the repo root here).
    const drainedOf = (cidv) => runHook(hook('post-tool-use'), { conversation_id: cidv });
    const anchorCid = 'npxv4';
    const repoDir = HOME;   // verify() runs under a pinned HOME; treat it as the repo
    const scopePath = join(repoDir, '.scope.json');
    const transcriptPath = join(HOME, '.cursor', '.hooks-pending', 'verify-transcript-npxv4.jsonl');
    const q1 = 'fix grid symmetry and color tokens';
    const q2 = 'now add dark mode support';

    const cleanup = () => {
      try { rmSync(scopePath, { force: true }); } catch {}
      try { rmSync(transcriptPath, { force: true }); } catch {}
    };
    cleanup();
    const writeTranscript = (q) =>
      writeFileSync(transcriptPath,
        JSON.stringify({ role: 'user', message: { content: `<user_query>${q}</user_query>` } }) + '\n',
        'utf8');

    // --- Case 0: no .scope.json + NO transcript -> do NOT write hollow scaffold
    // 0.6.1: never persist intent=<TODO> when the request is unreadable. Emit the
    // pre-compile demand so the agent authors a real contract from the chat.
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: repoDir });
    let d0 = drainedOf(anchorCid);
    if (existsSync(scopePath)) {
      cleanup(); return { ok: false, detail: 'hollow scaffold written without transcript (0.6.1 regression)' };
    }
    if (!d0.includes('INTENT ANCHOR (pre-compile)')) {
      cleanup(); return { ok: false, detail: 'no-transcript turn did not emit pre-compile demand' };
    }
    // Clear the latch so Case A starts fresh (with a real query this time).
    runHook(hook('final-review'), { conversation_id: anchorCid, status: 'completed' });
    cleanup();

    // --- Case A: no .scope.json + prompt q1 -> WRITE scaffold with q1 as intent -
    writeTranscript(q1);
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: repoDir, transcript_path: transcriptPath });
    let d = drainedOf(anchorCid);
    if (!existsSync(scopePath)) {
      cleanup(); return { ok: false, detail: 'scaffold was NOT written on first prompt' };
    }
    let scope;
    try { scope = JSON.parse(readFileSync(scopePath, 'utf8')); }
    catch { cleanup(); return { ok: false, detail: '.scope.json is not valid JSON' }; }
    if (scope.intent !== q1) {
      cleanup(); return { ok: false, detail: `intent mismatch (want "${q1}"): ${scope.intent}` };
    }
    if (!d.includes('scope regenerated')) {
      cleanup(); return { ok: false, detail: 'regenerated branch did not fire' };
    }

    // --- Stop clears the latch -> next turn can act again --------------------
    runHook(hook('final-review'), { conversation_id: anchorCid, status: 'completed' });

    // --- Case B: same prompt q1 again -> re-INJECT, do NOT rewrite ----------
    const sizeBefore = statSync(scopePath).size;
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: repoDir, transcript_path: transcriptPath });
    d = drainedOf(anchorCid);
    if (!d.includes('re-injected')) {
      cleanup(); return { ok: false, detail: 'same-prompt turn did not re-inject' };
    }
    // _intent_hash matches -> file must not have been regenerated. Intent still q1.
    try { scope = JSON.parse(readFileSync(scopePath, 'utf8')); }
    catch { cleanup(); return { ok: false, detail: '.scope.json corrupted on same-prompt turn' }; }
    if (scope.intent !== q1) {
      cleanup(); return { ok: false, detail: `same-prompt turn rewrote intent (should stay "${q1}"): ${scope.intent}` };
    }

    // --- Stop; new prompt q2 -> REGENERATE with q2 as intent ----------------
    runHook(hook('final-review'), { conversation_id: anchorCid, status: 'completed' });
    writeTranscript(q2);
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: repoDir, transcript_path: transcriptPath });
    d = drainedOf(anchorCid);
    try { scope = JSON.parse(readFileSync(scopePath, 'utf8')); }
    catch { cleanup(); return { ok: false, detail: '.scope.json corrupted on prompt-change turn' }; }
    if (scope.intent !== q2) {
      cleanup(); return { ok: false, detail: `prompt-change did not regenerate intent (want "${q2}"): ${scope.intent}` };
    }
    if (!d.includes('scope regenerated')) {
      cleanup(); return { ok: false, detail: 'prompt-change turn did not report regeneration' };
    }

    // --- The anti-ghost-file guard: no .scope.json should ever exist at $HOME
    //     level OUTSIDE the resolved repo. Here repo == HOME so this is moot,
    //     but assert the file has the _generated_by marker (proof the hook wrote
    //     it, and that it carries _intent_hash for self-contained staleness).
    if (!scope._generated_by || !scope._intent_hash) {
      cleanup(); return { ok: false, detail: 'scaffold missing _generated_by / _intent_hash fields' };
    }

    // --- Case C: MODEL-written scope (no _intent_hash) + a NEW prompt --------
    // Reproduces the shipped bug (chiquipuesto/WAVE): the model wrote .scope.json
    // per the legacy 4-field schema, so the hook could never detect staleness and
    // scope-gate kept appending files across features. A new prompt (fresh cid =>
    // promptChanged) must now REGENERATE and RESET files[].
    const mkT = (p, q) => writeFileSync(p,
      JSON.stringify({ role: 'user', message: { content: `<user_query>${q}</user_query>` } }) + '\n', 'utf8');
    const cidC = 'npxv5';
    const transcriptC = join(HOME, '.cursor', '.hooks-pending', 'verify-transcript-npxv5.jsonl');
    const failC = (detail) => { try { rmSync(transcriptC, { force: true }); } catch {} cleanup(); return { ok: false, detail }; };
    try { rmSync(scopePath, { force: true }); } catch {}
    writeFileSync(scopePath, JSON.stringify({ intent: q1, files: ['a.ts', 'b.ts'], acceptance: 'keep', allow_growth: false }, null, 2), 'utf8');
    mkT(transcriptC, q2);
    runHook(hook('intent-anchor'), { conversation_id: cidC, cwd: repoDir, transcript_path: transcriptC });
    drainedOf(cidC);
    let sc;
    try { sc = JSON.parse(readFileSync(scopePath, 'utf8')); } catch { return failC('model-written scope corrupted after new prompt'); }
    if (sc.intent !== q2) return failC(`carryover not regenerated (want "${q2}"): ${sc.intent}`);
    if (!Array.isArray(sc.files) || sc.files.length !== 0) return failC(`files[] not reset on regen: ${JSON.stringify(sc.files)}`);
    if (!sc._intent_hash) return failC('regen did not install _intent_hash');
    if (!sc.trace || sc.trace.query !== q2) return failC('regen did not record trace.query');
    runHook(hook('final-review'), { conversation_id: cidC, status: 'completed' });
    rmSync(transcriptC, { force: true });

    // --- Case D: MODEL-written scope (no _intent_hash) + the SAME prompt ------
    // The model wrote the contract for THIS request this session. The hook must
    // HEAL in place (backfill _intent_hash + trace) WITHOUT resetting files[] or
    // acceptance, so the NEXT prompt change is detectable by hash.
    const cidD = 'npxv6';
    const transcriptD = join(HOME, '.cursor', '.hooks-pending', 'verify-transcript-npxv6.jsonl');
    const failD = (detail) => { try { rmSync(transcriptD, { force: true }); } catch {} cleanup(); return { ok: false, detail }; };
    try { rmSync(scopePath, { force: true }); } catch {}
    mkT(transcriptD, q1);
    // prime last-query-<cidD>.hash with q1 (a hook-written scaffold), clear the
    // latch, then overwrite with a model-style scope for the SAME prompt.
    runHook(hook('intent-anchor'), { conversation_id: cidD, cwd: repoDir, transcript_path: transcriptD });
    runHook(hook('final-review'), { conversation_id: cidD, status: 'completed' });
    writeFileSync(scopePath, JSON.stringify({ intent: q1, files: ['a.ts', 'b.ts'], acceptance: 'keep me', allow_growth: false }, null, 2), 'utf8');
    runHook(hook('intent-anchor'), { conversation_id: cidD, cwd: repoDir, transcript_path: transcriptD });
    drainedOf(cidD);
    let sd;
    try { sd = JSON.parse(readFileSync(scopePath, 'utf8')); } catch { return failD('healed scope corrupted'); }
    if (!sd._intent_hash) return failD('heal did not backfill _intent_hash');
    if (!sd.trace) return failD('heal did not add trace');
    if (!Array.isArray(sd.files) || sd.files.join(',') !== 'a.ts,b.ts') return failD(`heal reset files[] (should preserve): ${JSON.stringify(sd.files)}`);
    if (sd.acceptance !== 'keep me') return failD(`heal clobbered acceptance: ${sd.acceptance}`);
    runHook(hook('final-review'), { conversation_id: cidD, status: 'completed' });
    rmSync(transcriptD, { force: true });

    cleanup();
    return true;
  });

  check('intent-precompile writes .scope.json before first token (no <TODO>)', () => {
    // THE contract-first guarantee: beforeSubmitPrompt materializes .scope.json
    // with intent locked from `prompt` and a SEEDED acceptance (never a bare
    // <TODO>), hash-gated so the agent's refinements survive a same-prompt turn
    // and a new prompt regenerates. If this regresses, the scope appears late
    // (via intent-anchor) and/or ships a <TODO> - the exact complaints.
    const preCid = 'npxv7';
    const repoDir = HOME;
    const scopePath = join(repoDir, '.scope.json');
    const promptPath = join(pendingDir, `current-prompt-${preCid}.txt`);
    const q1 = 'fix the dashboard bug in individual accounts';
    const q2 = 'now wire the spend chart to the new endpoint';
    const cleanup = () => {
      try { rmSync(scopePath, { force: true }); } catch {}
      try { rmSync(promptPath, { force: true }); } catch {}
    };
    const fail = (detail) => { cleanup(); return { ok: false, detail }; };
    cleanup();

    // Case A: new prompt -> WRITE .scope.json with intent=q1, real acceptance, hash.
    runHook(hook('intent-precompile'), { conversation_id: preCid, cwd: repoDir, prompt: q1 });
    if (!existsSync(scopePath)) return fail('intent-precompile did not write .scope.json');
    let s;
    try { s = JSON.parse(readFileSync(scopePath, 'utf8')); }
    catch { return fail('.scope.json is not valid JSON'); }
    if (s.intent !== q1) return fail(`intent mismatch (want q1): ${s.intent}`);
    if (!s.acceptance || /<TODO/i.test(s.acceptance)) return fail('acceptance is a bare <TODO> (the regression)');
    if (!s._generated_by || !/intent-precompile/i.test(s._generated_by)) return fail(`not written by intent-precompile: ${s._generated_by}`);
    if (!s._intent_hash) return fail('missing _intent_hash (per-prompt regeneration breaks)');

    // Case B: same prompt -> NOT rewritten (hash-gated; agent refinements survive).
    writeFileSync(scopePath, JSON.stringify({ ...s, acceptance: 'AGENT-SENTINEL' }, null, 2), 'utf8');
    runHook(hook('intent-precompile'), { conversation_id: preCid, cwd: repoDir, prompt: q1 });
    let sb;
    try { sb = JSON.parse(readFileSync(scopePath, 'utf8')); } catch { return fail('same-prompt run corrupted the file'); }
    if (sb.acceptance !== 'AGENT-SENTINEL') return fail('same-prompt run overwrote the agent refinement (must be left intact)');

    // Case C: new prompt -> REGENERATE with intent=q2, and stash the verbatim prompt
    // so intent-anchor gets ground truth even when beforeSubmitPrompt lacks cwd.
    runHook(hook('intent-precompile'), { conversation_id: preCid, cwd: repoDir, prompt: q2 });
    let sc;
    try { sc = JSON.parse(readFileSync(scopePath, 'utf8')); } catch { return fail('new-prompt run corrupted the file'); }
    if (sc.intent !== q2) return fail(`new prompt did not regenerate (want q2): ${sc.intent}`);
    if (!existsSync(promptPath) || readFileSync(promptPath, 'utf8') !== q2) return fail('verbatim prompt not stashed for intent-anchor');

    cleanup();
    return true;
  });

  check('doctrine injection emits additional_context', () =>
    runHook(join(cursorDst, injectName), {}).includes('additional_context'));

  const py = pythonCmd();
  const scanner = join(skillDst, 'scripts', 'scan_slop.py');
  let scannerOk = false;
  if (py && existsSync(scanner)) {
    const r = spawnSync(py, [scanner, '--help'], { encoding: 'utf8', timeout: 20000, windowsHide: true });
    scannerOk = !r.error && /usage/i.test(`${r.stdout || ''}${r.stderr || ''}`);
  }
  console.log(`  ${scannerOk ? ' ok ' : 'warn'}  anti-slop scanner --help${scannerOk ? '' : ' — unavailable (final review falls back to the checklist)'}`);

  check('sweep runs and emits a structured report', () => {
    // Sweep spawns the scanner in --all --format json and prints a category
    // breakdown. We assert it runs and prints the two anchor lines every
    // outcome shares (sloppy or clean), so a regression in the parser or the
    // spawn wiring surfaces here instead of at sweep time.
    const r = spawnSync(process.execPath, [join(pkgRoot, 'bin', 'cli.mjs'), 'sweep', pkgRoot], {
      encoding: 'utf8', timeout: 120000, windowsHide: true,
      env: { ...process.env, HOME, USERPROFILE: HOME },
      maxBuffer: 64 * 1024 * 1024,
    });
    const out = `${r.stdout || ''}${r.stderr || ''}`;
    if (r.status !== 0 || r.error) return { ok: false, detail: `exit ${r.status} ${r.error ? r.error.message : ''}` };
    if (!/anti-slop sweep \(whole codebase\)/.test(out)) return { ok: false, detail: 'missing sweep header' };
    if (!/slop_found:/.test(out)) return { ok: false, detail: 'missing slop_found verdict line' };
    return true;
  });

  // Clean up verification state so the next real session starts fresh.
  if (existsSync(pendingDir)) {
    for (const f of readdirSync(pendingDir)) {
      if (f.includes('npxv')) rmSync(join(pendingDir, f), { force: true });
    }
  }

  const failed = results.filter((r) => !r.ok);
  console.log('');
  if (failed.length) {
    console.error(`${failed.length} check(s) failed. Re-run: npx cursordoctrine install`);
    process.exit(1);
  }
  console.log('All checks passed. Restart Cursor if you have not since installing.');
}

// Whole-codebase anti-slop sweep. Runs the scanner in AUDIT mode (--all) and
// prints a structured, category-by-category breakdown of every slop signal in
// the repo. This is the COMPREHENSIVE counterpart to the bounded session
// final-review: it explicitly authorizes fixing pre-existing slop (the session
// review forbids that, correctly). The scanner is reports-only and never edits;
// this command is too — it hands the deterministic inventory plus a cleanup
// doctrine to the agent, which iterates scan->fix->re-scan until clean.
//
// Why scan-only here: the scanner is deliberately dumb and high-precision
// (it refuses to guess semantic slop). The fixing needs judgement (is a clone
// load-bearing? is a swallowed error a legit best-effort cleanup?), which is
// the model's job, not a script's. The doctrine pins the order and the
// re-scan-after-each-category loop so the agent can't drift.
function sweep() {
  const root = resolve(process.argv[3] || '.');
  console.log(`cursordoctrine ${pkg.version} — anti-slop sweep (whole codebase)`);
  console.log(`  root   ${root}`);
  if (!existsSync(join(root, '.git'))) {
    console.log('  note: not a git root; --all scans tracked files, so results may be partial.');
  }
  console.log('');

  const scanner = join(skillDst, 'scripts', 'scan_slop.py');
  if (!existsSync(scanner)) {
    console.error('anti-slop skill not installed. Run: npx cursordoctrine install');
    process.exit(1);
  }
  const py = pythonCmd();
  if (!py) {
    console.error('Python 3.9+ not found — the scanner cannot run.');
    console.error('Install Python, then re-run.');
    process.exit(1);
  }

  // --all --format json: the deterministic inventory. --format json so we can
  // parse totals + group signals by category for a readable report.
  const r = spawnSync(py, [scanner, '--all', '--format', 'json', '--root', root], {
    encoding: 'utf8',
    timeout: 120000,
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) {
    console.error(`scanner failed to run: ${r.error.message}`);
    process.exit(1);
  }
  let data;
  try {
    data = JSON.parse(`${r.stdout || ''}`);
  } catch (e) {
    console.error('scanner produced unparseable output.');
    if (r.stderr) console.error(r.stderr);
    process.exit(1);
  }

  const totals = data.totals || {};
  const dup = data.duplication || {};
  const nFiles = data.files_scanned || 0;
  const warnings = data.warnings || [];

  console.log(`scanned ${nFiles} file(s)   slop_found: ${data.slop_found ? 'YES' : 'no'}`);
  for (const w of warnings) console.log(`  note: ${w}`);
  console.log('');

  if (!data.slop_found) {
    console.log('No static slop signals across the codebase. Clean of the');
    console.log('deterministic inventory. (Semantic slop — cargo-cult, superficial');
    console.log('tests — still needs a model pass; invoke the anti-slop skill.)');
    return;
  }

  // Group per-file signals by category, mapping scanner keys to human labels.
  // Order matches the cleanup doctrine (cheapest/highest-precision first).
  const categories = [
    ['swallowed_errors', 'SWALLOWED ERRORS', 'empty catch / broad except+pass'],
    ['abstractions', 'PREMATURE ABSTRACTIONS', 'Factory/Repository/CQRS with <2 call sites'],
    ['dependencies', 'NEW DEPENDENCIES', 'lib for something stdlib/existing dep covers'],
    ['type_escapes', 'TYPE ESCAPES', 'as any / as unknown / @ts-ignore / type:ignore'],
    ['tautological_tests', 'TAUTOLOGICAL TESTS', 'assertion that cannot fail (trivially true)'],
    ['async_wrappers', 'ASYNC WRAPPERS', 'await Promise.resolve / pointless async'],
    ['guard_chains', 'GUARD CHAINS', 'deepening optional-chaining guard shape'],
    ['boolean_traps', 'BOOLEAN TRAPS', 'flag-flip call sites: fn(x, true)'],
    ['select_star', 'SELECT *', 'SELECT * in .sql'],
    ['tailwind_slop', 'TAILWIND SLOP', 'class soup / magic px / z-[9999] / hardcoded hex'],
    ['redundant_comments', 'REDUNDANT COMMENTS', 'restates the code // WHAT not WHY'],
    ['ai_residue', 'AI RESIDUE', 'placeholder phrases / banner comments / emoji'],
    ['semantic_density', 'SEMANTIC OPACITY', 'DataManager / process() / utils.ts / Pt'],
  ];

  const printFileList = (heading, count, files, maxShow = 8) => {
    console.log(`  ${heading}: ${count}`);
    const shown = files.slice(0, maxShow);
    for (const f of shown) console.log(`      ${f}`);
    if (files.length > maxShow) console.log(`      ... +${files.length - maxShow} more`);
  };

  for (const [key, label, desc] of categories) {
    if (!totals[key]) continue;
    const filesWith = [];
    for (const f of data.files || []) {
      if (f[key] && f[key].length) filesWith.push(`${f.file}  (${f[key].length})`);
    }
    console.log(`${label} — ${desc}`);
    printFileList('files', filesWith.length, filesWith);
    console.log('');
  }

  // Duplication block (the isRecord-class slop). The doctrine orders these first;
  // we print them after per-file only because the summary count rolls them up.
  const dupCount = (dup.name_clones?.length || 0) + (dup.body_clones?.length || 0)
    + (dup.near_clones?.length || 0) + (dup.single_use?.length || 0)
    + (dup.type_clones?.length || 0);
  if (dupCount || dup.fingerprints && Object.keys(dup.fingerprints).length) {
    console.log('DUPLICATION (isRecord-class slop):');
    const dupRows = [
      ['name_clones', 'Clone proliferation', 'same name in >=2 files'],
      ['body_clones', 'Knowledge duplication', 'identical body (DRY -> ONE)'],
      ['near_clones', 'Semantic fragmentation', 'drifted clones (same shape)'],
      ['single_use', 'Single-use / dead helpers', 'inline then delete'],
      ['type_clones', 'Duplicate type/interface', 'consolidate across files'],
    ];
    for (const [k, label, desc] of dupRows) {
      const arr = dup[k] || [];
      if (!arr.length) continue;
      console.log(`  ${label} — ${desc}: ${arr.length}`);
      for (const c of arr.slice(0, 6)) {
        const names = (c.names || []).join('/');
        const fls = (c.files || []).slice(0, 3).join(', ');
        const more = (c.files || []).length > 3 ? `, +${c.files.length - 3}` : '';
        console.log(`      ${names || '(unnamed)'}  x${c.count || arr.length}  ${fls}${more}`);
      }
      if (arr.length > 6) console.log(`      ... +${arr.length - 6} more`);
    }
    if (dup.fingerprints && Object.keys(dup.fingerprints).length) {
      console.log(`  GENERATED FINGERPRINTS: ${Object.keys(dup.fingerprints).join(', ')}`);
    }
    if (dup.micro_count) {
      console.log(`  micro-abstraction load: ${dup.micro_count} tiny is*/assert*/safe* helper(s)`
        + ` of ${dup.total_defs || '?'} defs (Helper Hell risk)`);
    }
    console.log('');
  }

  // Summary counts for a one-line read.
  const parts = [];
  for (const [k, label] of categories) if (totals[k]) parts.push(`${totals[k]} ${label.toLowerCase().replace(/ /g, '-')}`);
  console.log(`SUMMARY (audit): ${parts.join(', ') || 'no per-file slop signals'}`);
  console.log('');

  // Hand off to the agent. The cleanup doctrine pins the order and the
  // scan->fix->re-scan loop; the scanner stays the deterministic source of
  // truth ("STILL failing?" == "not fixed"). Bounded by the agent's own loop
  // limit; this command is a single deterministic pass.
  const doctrine = join(hooksDst, 'cleanup-doctrine.md');
  const doctrineExists = existsSync(doctrine);
  const scanAgain = `${py} ${scanner.replaceAll('\\', '/')} --all --root .`;
  console.log('NEXT — fix the signals above, in this order:');
  console.log('  1. Read the cleanup doctrine' + (doctrineExists ? ` at ${doctrine.replaceAll('\\', '/')}` : '') + '.');
  console.log('  2. Work category-by-category; after EACH, re-run the scan and confirm');
  console.log('     that category hit zero before moving on:');
  console.log(`     ${scanAgain}`);
  console.log('  3. Do NOT change observable behavior the project depends on. Prefer');
  console.log('     rename -> re-point imports -> delete-copy. Run typecheck/build/tests');
  console.log('     after each category; if something breaks, back it out and flag it.');
  console.log('  4. Target end state: `slop_found: false`, or a residual you justified');
  console.log('     as load-bearing. Do not weaken real code to chase a clean scan.');
}

function uninstall() {
  console.log(`cursordoctrine ${pkg.version} — removing the ${platform} hook pack from ${HOME}`);

  const removed = [];
  for (const f of payloadHookFiles()) {
    const p = join(hooksDst, f);
    if (existsSync(p)) {
      rmSync(p, { force: true });
      removed.push(`~/.agents/hooks/${f}`);
    }
  }
  for (const f of doctrineFiles) {
    const p = join(cursorDst, f);
    if (existsSync(p)) {
      rmSync(p, { force: true });
      removed.push(`~/.cursor/${f}`);
    }
  }
  if (existsSync(skillDst)) {
    rmSync(skillDst, { recursive: true, force: true });
    removed.push('~/.cursor/skills/anti-slop/');
  }
  if (existsSync(pendingDir)) {
    rmSync(pendingDir, { recursive: true, force: true });
    removed.push('~/.cursor/.hooks-pending/');
  }

  if (existsSync(hooksJsonDst)) {
    try {
      const existing = JSON.parse(readFileSync(hooksJsonDst, 'utf8'));
      const keys = ourKeys();
      let foreign = 0;
      for (const [event, entries] of Object.entries(existing.hooks || {})) {
        if (!Array.isArray(entries)) continue;
        // Remove both current ours AND stale ours (commands referencing scripts
        // this pack no longer ships - leftovers from prior versions). Pure
        // foreign entries are kept, same as before.
        existing.hooks[event] = entries.filter(
          (x) => !x || (!isOurs(x.command, keys) && !isStaleOurs(x.command))
        );
        foreign += existing.hooks[event].length;
        if (existing.hooks[event].length === 0) delete existing.hooks[event];
      }
      if (foreign === 0) {
        rmSync(hooksJsonDst, { force: true });
        removed.push('~/.cursor/hooks.json');
      } else {
        writeFileSync(hooksJsonDst, JSON.stringify(existing, null, 2) + '\n');
        removed.push(`~/.cursor/hooks.json (ours stripped, ${foreign} foreign entr${foreign === 1 ? 'y' : 'ies'} kept)`);
      }
    } catch {
      console.log('  warning: ~/.cursor/hooks.json is not valid JSON — left untouched.');
    }
  }

  console.log('');
  for (const r of removed) console.log(`  removed  ${r}`);
  if (removed.length === 0) console.log('  nothing to remove.');
  console.log('');
  console.log('Done. Restart Cursor to unload the hooks.');
}

function help() {
  console.log(`cursordoctrine ${pkg.version} — thin self-review hooks for Cursor; the model is the auditor

Usage
  npx cursordoctrine <command>

Commands
  install      Install the hook pack, doctrine, and anti-slop skill into $HOME.
               Merges ~/.cursor/hooks.json — entries you added yourself are preserved.
  verify       Smoke-test every installed hook with fake payloads (no Cursor restart needed).
  sweep        Whole-codebase anti-slop audit: scan every file, print a category-by-
               category breakdown, hand off to the agent to fix pre-existing slop
               (the bounded session review does NOT touch pre-existing slop).
  uninstall    Remove installed files and strip our hooks.json entries.
  help         Show this help.

After install
  Restart Cursor — hooks.json is read at startup.

Examples
  npx cursordoctrine@latest install
  npx cursordoctrine verify
  npx cursordoctrine sweep
  npx cursordoctrine uninstall

Kill switches (environment variables, all hooks fail open)
  HOOKS_ENFORCE=0              everything advisory off
  PERM_GATE_ENFORCE=0          permission gate off
  INTENT_ANCHOR_ENFORCE=0      thin-intent scaffold/re-injection off
  SEMANTIC_DENSITY_ENFORCE=0   semantic-opacity advisory off
  SCOPE_GATE_ENFORCE=0         declared-scope advisory off
  ANTI_SLOP_ENFORCE=0          slop advisory off
  FINAL_REVIEW_ENFORCE=0       final review off
  SUBAGENT_REVIEW_ENFORCE=0    in-subagent review off

Docs  https://github.com/kleosr/cursordoctrine`);
}

const cmd = process.argv[2];
switch (cmd) {
  case 'install':
  case 'i':
    install();
    break;
  case 'verify':
  case 'check':
    verify();
    break;
  case 'sweep':
    sweep();
    break;
  case 'uninstall':
  case 'remove':
  case 'rm':
    uninstall();
    break;
  case 'version':
  case '--version':
  case '-v':
    console.log(pkg.version);
    break;
  case undefined:
  case 'help':
  case '--help':
  case '-h':
    help();
    break;
  default:
    console.error(`Unknown command: ${cmd}\n`);
    help();
    process.exit(2);
}
