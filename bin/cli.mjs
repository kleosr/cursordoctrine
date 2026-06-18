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
    // Re-order our entries to match the shipped hooks.json (merge used to leave
    // stale order — e.g. post-tool-use before intent-anchor — breaking same-tool
    // delivery of the anchor message).
    const foreign = cur.filter((x) => x && !isOurs(x.command, keys));
    const reordered = [];
    const used = new Set();
    for (const entry of entries) {
      const k = keyOf(entry.command, keys);
      if (!k || !isOurs(entry.command, keys)) continue;
      const found = cur.find((x) => x && keyOf(x.command, keys) === k);
      if (found) {
        reordered.push(found);
        used.add(k);
      }
    }
    for (const x of cur) {
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

  check('anchor-set nudge fires once per turn, stop re-arms it', () => {
    // anchor-set-nudge appends to feedback-<cid>.txt (the shared bus) rather
    // than emitting JSON directly; drain it the same way post-tool-use does.
    const drainedOf = (cidv) => runHook(hook('post-tool-use'), { conversation_id: cidv });

    // --- Turn 1 -------------------------------------------------------------
    // First edit -> nudge stashes into the feedback bus and arms the latch.
    runHook(hook('anchor-set-nudge'), { conversation_id: 'npxv3', file_path: join(HOME, 'x.py') });
    if (!drainedOf('npxv3').includes('PRE-COMPILE NUDGE')) {
      return { ok: false, detail: 'nudge did not reach the feedback bus on first edit' };
    }
    // Second edit same turn -> latch armed, nudge must stay silent.
    runHook(hook('anchor-set-nudge'), { conversation_id: 'npxv3', file_path: join(HOME, 'y.py') });
    if (drainedOf('npxv3').includes('PRE-COMPILE NUDGE')) {
      return { ok: false, detail: 'nudge re-fired on second edit (latch not gating)' };
    }
    // End of turn: final-review clears the latch unconditionally. Drive a
    // review-less stop (no session-edits marker) so it hits the clear path and
    // exits {}, same as a turn that produced no reviewable edits.
    const stopOut = runHook(hook('final-review'), { conversation_id: 'npxv3', status: 'completed' });
    if (stopOut !== '{}' && stopOut.replace(/\s/g, '') !== '{}') {
      // A review fired (fine - the earlier edit left a session-edits marker via
      // self-review-trigger if one ran). What matters is the latch got cleared;
      // we verify that with the next-turn re-fire below.
    }
    // --- Turn 2 -------------------------------------------------------------
    // First edit of the NEXT turn -> latch was cleared at the stop boundary, so
    // the nudge MUST re-fire. This is the regression that 0.4.0 shipped broken:
    // the latch only cleared on the fragile second-stop path, so it stranded
    // and the nudge went permanently silent mid-session.
    runHook(hook('anchor-set-nudge'), { conversation_id: 'npxv3', file_path: join(HOME, 'z.py') });
    if (!drainedOf('npxv3').includes('PRE-COMPILE NUDGE')) {
      return { ok: false, detail: 'nudge did NOT re-fire on the next turn (latch stranded at the stop boundary)' };
    }
    return true;
  });

  check('intent-anchor scaffolds .scope.json and re-injects every turn', () => {
    const drainedOf = (cidv) => runHook(hook('post-tool-use'), { conversation_id: cidv });
    const anchorCid = 'npxv4';
    const scopePath = join(HOME, '.scope.json');
    const transcriptPath = join(HOME, '.cursor', '.hooks-pending', 'verify-transcript-npxv4.jsonl');
    const testQuery = 'fix grid symmetry and color tokens';

    const cleanup = () => {
      try { rmSync(scopePath, { force: true }); } catch {}
      try { rmSync(transcriptPath, { force: true }); } catch {}
    };
    cleanup();

    // Fake transcript so Get-LastUserQuery / scaffold can read the request.
    const transcriptLine = JSON.stringify({
      role: 'user',
      message: { content: `<user_query>${testQuery}</user_query>` },
    });
    writeFileSync(transcriptPath, transcriptLine + '\n', 'utf8');

    const anchorPayload = { conversation_id: anchorCid, cwd: HOME, transcript_path: transcriptPath };

    // --- Case A: no .scope.json -> hook writes scaffold on disk ----------
    runHook(hook('intent-anchor'), anchorPayload);
    let d = drainedOf(anchorCid);
    if (!existsSync(scopePath)) {
      cleanup(); return { ok: false, detail: '.scope.json was not written to disk' };
    }
    let scope;
    try { scope = JSON.parse(readFileSync(scopePath, 'utf8')); } catch {
      cleanup(); return { ok: false, detail: '.scope.json scaffold is not valid JSON' };
    }
    if (scope.intent !== testQuery) {
      cleanup(); return { ok: false, detail: `scaffold intent mismatch: ${scope.intent}` };
    }
    if (!d.includes('scaffold written') || !d.includes(testQuery)) {
      cleanup(); return { ok: false, detail: 'scaffold branch did not inject written contract' };
    }

    // --- Stop clears the latch -------------------------------------------
    runHook(hook('final-review'), { conversation_id: anchorCid, status: 'completed' });

    // --- Case B: scope exists -> re-inject contract every turn -----------
    writeFileSync(scopePath, JSON.stringify({
      intent: 'fix grid symmetry and color tokens',
      files: ['src/grid.tsx'],
      acceptance: 'grid renders symmetric; tokens match palette',
    }));
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: HOME, transcript_path: transcriptPath });
    d = drainedOf(anchorCid);
    if (!d.includes('fix grid symmetry and color tokens') || !d.includes('INTENT ANCHOR')) {
      cleanup(); return { ok: false, detail: 'contract not re-injected on turn 2' };
    }

    runHook(hook('final-review'), { conversation_id: anchorCid, status: 'completed' });
    runHook(hook('intent-anchor'), { conversation_id: anchorCid, cwd: HOME, transcript_path: transcriptPath });
    d = drainedOf(anchorCid);
    if (!d.includes('fix grid symmetry and color tokens')) {
      cleanup(); return { ok: false, detail: 'contract not re-injected on turn 3 (latch stranded at stop)' };
    }
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
        existing.hooks[event] = entries.filter((x) => !isOurs(x?.command, keys));
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
  uninstall    Remove installed files and strip our hooks.json entries.
  help         Show this help.

After install
  Restart Cursor — hooks.json is read at startup.

Examples
  npx cursordoctrine@latest install
  npx cursordoctrine verify
  npx cursordoctrine uninstall

Kill switches (environment variables, all hooks fail open)
  HOOKS_ENFORCE=0              everything advisory off
  PERM_GATE_ENFORCE=0          permission gate off
  ANCHOR_NUDGE_ENFORCE=0       pre-compile nudge off (first-edit Anchor Set reminder)
  INTENT_ANCHOR_ENFORCE=0      thin-intent re-injection off (per-turn .scope.json echo)
  MINIMAL_EDITING_ENFORCE=0    over-edit advisory off (deprecated in 0.3.0)
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
