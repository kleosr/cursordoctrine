#!/usr/bin/env node
// cursordoctrine — one-command installer for the cursordoctrine hook pack.
//
// The payload ships inside this npm package (windows/, linux/, skills/).
// `install` removes any prior cursordoctrine pack from $HOME, then copies the
// new payload (windows/, linux/, skills/), merging ~/.cursor/hooks.json instead of overwriting it. `verify` smoke-tests
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
const doctrineFiles = [injectName, 'doctrine.md'];

// Hook scripts this pack used to ship but no longer does. install() deletes
// these from ~/.agents/hooks so a version bump cannot leave orphans that call
// functions removed from hook-common. Only explicit basenames — never wildcards.
const STALE_HOOK_FILES = [
  'anti-slop-audit.ps1', 'anti-slop-audit.sh',
  'post-tool-use.ps1', 'post-tool-use.sh',
  'scope-gate-audit.ps1', 'scope-gate-audit.sh',
  'self-review-trigger.ps1', 'self-review-trigger.sh',
  'semantic-density-audit.ps1', 'semantic-density-audit.sh',
  'subagent-stop-review.ps1', 'subagent-stop-review.sh',
  'self-review.md',
  'biome-advisory.ps1', 'biome-advisory.sh',
  'semgrep-advisory.ps1', 'semgrep-advisory.sh',
  'anchor-set-nudge.ps1', 'anchor-set-nudge.sh',
  'minimal-edit-audit.ps1', 'minimal-edit-audit.sh',
];

// Doctrine files removed from the sessionStart payload across versions.
const STALE_CURSOR_FILES = ['pre-compile.md', 'USER-RULES.md', 'declared-editing.md'];

function payloadHookFiles() {
  return readdirSync(join(payload, 'hooks'));
}

// An entry in hooks.json is "ours" when its command references one of the
// script filenames we ship (hook scripts or the inject-doctrine script).
function ourKeys() {
  return [...payloadHookFiles().filter((f) => !f.endsWith('.md')), injectName];
}

function commandReferencesOurPath(command, key) {
  if (typeof command !== 'string') return false;
  const c = command.replaceAll('\\', '/').toLowerCase();
  const k = key.toLowerCase();
  if (k === injectName.toLowerCase()) {
    return c.includes(`~/.cursor/${k}`) || c.includes(`/.cursor/${k}`);
  }
  return c.includes(`~/.agents/hooks/${k}`) || c.includes(`/.agents/hooks/${k}`);
}

function isOurs(command, keys) {
  return typeof command === 'string' && keys.some((k) => commandReferencesOurPath(command, k));
}

function keyOf(command, keys) {
  if (typeof command !== 'string') return undefined;
  return keys.find((k) => commandReferencesOurPath(command, k));
}

// Detect a STALE entry from a prior install: its command names one of the hook
// scripts THIS pack used to ship but no longer does (the explicit STALE_HOOK_FILES
// roster — e.g. anchor-set-nudge / minimal-edit-audit, deleted in 0.5.0). The old
// merge preserved them as "foreign", so deleted hooks kept running on every edit
// silently. Returning true here makes install reap them.
//
// Gate on the KNOWN roster, not "any *.ps1/*.sh not in the current payload":
// a user's own hook (~/.agents/hooks/my-custom-gate.ps1) also matches the
// filename shape and is NOT in the payload, so the old broad check reaped it on
// every install — dropping a genuinely foreign entry and, once it was the only
// foreign entry, making uninstall delete hooks.json outright. STALE_HOOK_FILES
// already lists every orphan this pack ever shipped, so the narrow check still
// reaps all legacy hooks while leaving foreign entries untouched.
const HOOK_FILENAME_RE = /([\w.\-]+)\.(ps1|sh)\b/;
const INJECT_RE = /\binject-doctrine\.(ps1|sh)\b/;
function isStaleOurs(command) {
  if (typeof command !== 'string') return false;
  const hookMatch = command.match(HOOK_FILENAME_RE);
  if (hookMatch) {
    const fname = `${hookMatch[1]}.${hookMatch[2]}`;
    // Only OUR retired hooks are stale. A name we never shipped is foreign —
    // leave it. A name still in the payload is current ours (handled elsewhere).
    return STALE_HOOK_FILES.includes(fname);
  }
  if (INJECT_RE.test(command)) {
    return !doctrineFiles.includes(injectName);
  }
  return false;
}

// declared: best-effort verify fixture cleanup; EBUSY on locked temp dirs may still throw on Windows
function rmBestEffort(path, opts = { force: true }) {
  if (existsSync(path)) rmSync(path, opts);
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
  // Final sweep: reap stale-ours entries from ALL events, including those that
  // exist only in the prior config (e.g. afterFileEdit / postToolUse /
  // subagentStop when the new pack no longer ships hooks for those events).
  // The main loop above only touches events present in `incoming`, so without
  // this pass deleted hooks from a prior install would survive the merge.
  for (const event of Object.keys(out.hooks)) {
    if (!Array.isArray(out.hooks[event])) continue;
    out.hooks[event] = out.hooks[event].filter((x) => x && !isStaleOurs(x.command));
    if (out.hooks[event].length === 0) delete out.hooks[event];
  }
  let preserved = 0;
  for (const entries of Object.values(out.hooks)) {
    if (Array.isArray(entries)) preserved += entries.filter((x) => !isOurs(x?.command, keys)).length;
  }
  return { merged: out, preserved };
}

// Remove every file and hooks.json entry this pack owns. Used by uninstall()
// and at the start of install() so `npx cursordoctrine@latest install` always
// upgrades from a clean slate (foreign hooks.json entries are preserved).
function removeOurPack() {
  const removed = [];
  const keys = ourKeys();

  for (const f of payloadHookFiles()) {
    const p = join(hooksDst, f);
    if (existsSync(p)) {
      rmSync(p, { force: true });
      removed.push(`~/.agents/hooks/${f}`);
    }
  }
  for (const f of STALE_HOOK_FILES) {
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
  for (const f of STALE_CURSOR_FILES) {
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
      let foreign = 0;
      for (const [event, entries] of Object.entries(existing.hooks || {})) {
        if (!Array.isArray(entries)) continue;
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
      // Invalid JSON left for install() to back up and rewrite.
    }
  }

  return removed;
}

function install() {
  console.log(`cursordoctrine ${pkg.version} — installing the ${platform} hook pack into ${HOME}`);
  if (process.platform === 'darwin') {
    console.log('  note: macOS detected — installing the Linux (bash) hook pack.');
  }
  const removedPrior = removeOurPack();
  if (removedPrior.length) {
    console.log(`  removed prior install  ${removedPrior.length} item(s)`);
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
  const incoming = JSON.parse(text);
  if (platform === 'windows') {
    const homeFwd = HOME.replaceAll('\\', '/');
    for (const entries of Object.values(incoming.hooks || {})) {
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (entry && typeof entry.command === 'string') {
          entry.command = entry.command.replace(/-File ~\/([^\s"]+)/g, `-File "${homeFwd}/$1"`);
        }
      }
    }
  }
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
        const mF = cmd.match(/-File\s+(?:"([^"]+)"|([^\s]+))/);
        if (mF) path = mF[1] || mF[2];
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

  // The merge must PRESERVE a hook the user added themselves and REAP one of our
  // retired hooks, without confusing the two. A foreign entry whose command names
  // a *.ps1/*.sh file (the common case) once tripped the stale-hook reaper and was
  // silently dropped on every install; this check would have caught that.
  check('merge preserves a foreign hook and reaps a retired one', () => {
    const keys = ourKeys();
    const foreignCmd = platform === 'windows'
      ? 'pwsh.exe -NoProfile -File ~/.agents/hooks/my-custom-gate.ps1'
      : 'bash ~/.agents/hooks/my-custom-gate.sh';
    const staleName = STALE_HOOK_FILES.find((f) => f.endsWith(platform === 'windows' ? '.ps1' : '.sh'));
    const staleCmd = platform === 'windows'
      ? `pwsh.exe -NoProfile -File ~/.agents/hooks/${staleName}`
      : `bash ~/.agents/hooks/${staleName}`;
    const incoming = JSON.parse(readFileSync(join(payload, 'hooks.json'), 'utf8'));
    const existing = {
      version: 1,
      hooks: { beforeShellExecution: [{ command: foreignCmd, timeout: 5 }, { command: staleCmd, timeout: 5 }] },
    };
    const { merged } = mergeHooks(existing, incoming, keys);
    const cmds = [];
    for (const entries of Object.values(merged.hooks || {})) {
      if (Array.isArray(entries)) for (const e of entries) if (e && e.command) cmds.push(e.command);
    }
    if (!cmds.some((c) => c.includes('my-custom-gate'))) {
      return { ok: false, detail: 'foreign hook was dropped by the merge' };
    }
    if (cmds.some((c) => c.includes(staleName))) {
      return { ok: false, detail: `retired hook ${staleName} survived the merge` };
    }
    return true;
  });

  check('merge leaves one cursordoctrine final-review stop hook', () => {
    const keys = ourKeys();
    const incoming = JSON.parse(readFileSync(join(payload, 'hooks.json'), 'utf8'));
    const currentStop = incoming.hooks.stop.find((e) => e.command.includes('final-review'));
    const duplicateStop = structuredClone(currentStop);
    const existing = {
      version: 1,
      hooks: { stop: [currentStop, duplicateStop, { command: 'bash ~/.agents/hooks/foreign-stop.sh', timeout: 5 }] },
    };
    const { merged } = mergeHooks(existing, incoming, keys);
    const ours = (merged.hooks.stop || []).filter((e) => keyOf(e.command, keys) === keyOf(currentStop.command, keys));
    const foreign = (merged.hooks.stop || []).filter((e) => e.command && e.command.includes('foreign-stop'));
    if (ours.length !== 1) return { ok: false, detail: `expected 1 final-review hook, got ${ours.length}` };
    if (foreign.length !== 1) return { ok: false, detail: 'foreign stop hook was not preserved' };
    return true;
  });

  check('install removes prior pack before writing new hooks', () => {
    const sandbox = join(HOME, '.cd-verify-install-upgrade');
    const staleName = STALE_HOOK_FILES.find((f) => f.endsWith(platform === 'windows' ? '.ps1' : '.sh'));
    if (!staleName) return { ok: false, detail: 'no stale hook fixture for platform' };
    const sandboxHooks = join(sandbox, '.agents', 'hooks');
    const sandboxPending = join(sandbox, '.cursor', '.hooks-pending');
    const stalePath = join(sandboxHooks, staleName);
    const cliPath = join(pkgRoot, 'bin/cli.mjs');
    const sandboxEnv = { ...process.env, CURSORDOCTRINE_HOME: sandbox, HOME: sandbox, USERPROFILE: sandbox };
    try {
      rmSync(sandbox, { recursive: true, force: true });
      mkdirSync(sandboxHooks, { recursive: true });
      mkdirSync(sandboxPending, { recursive: true });
      writeFileSync(stalePath, '# stale leftover from prior version\n');
      writeFileSync(join(sandboxPending, 'old.flag'), '1');
      const r = spawnSync(process.execPath, [cliPath, 'install'], {
        env: sandboxEnv,
        encoding: 'utf8',
        timeout: 30000,
        windowsHide: true,
      });
      if (r.status !== 0) {
        return { ok: false, detail: `install exited ${r.status}: ${(r.stderr || r.stdout || '').slice(0, 200)}` };
      }
      if (existsSync(stalePath)) return { ok: false, detail: `${staleName} survived install upgrade` };
      if (existsSync(join(sandboxPending, 'old.flag'))) {
        return { ok: false, detail: '.hooks-pending not cleared on upgrade install' };
      }
      const anchor = join(sandboxHooks, `intent-anchor.${platform === 'windows' ? 'ps1' : 'sh'}`);
      if (!existsSync(anchor)) return { ok: false, detail: 'fresh hooks were not installed' };
      return true;
    } finally {
      rmBestEffort(sandbox, { recursive: true, force: true });
    }
  });

  check('permission gate denies `git push --force`', () =>
    /"permission"\s*:\s*"deny"/.test(runHook(hook('permission-gate'), { command: 'git push --force' })));

  check('step0-gate denies code edit when intent empty', () => {
    const repoDir = join(HOME, '.cd-verify-step0-empty');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(join(repoDir, 'package.json'), '{}');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix foo',
        intent: '',
        decomposition: [],
        verifications: [],
        files: [],
        acceptance: 'tests pass',
      }));
      const out = runHook(hook('step0-gate'), {
        cwd: repoDir,
        tool_name: 'Write',
        tool_input: { path: join(repoDir, 'src/foo.ts') },
      });
      if (!/"permission"\s*:\s*"deny"/.test(out)) {
        return { ok: false, detail: `expected deny, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('step0-gate allows .scope.json write when intent empty', () => {
    const repoDir = join(HOME, '.cd-verify-step0-scope');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(join(repoDir, 'package.json'), '{}');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix foo',
        intent: '',
        decomposition: [],
        verifications: [],
        files: [],
        acceptance: 'tests pass',
      }));
      const out = runHook(hook('step0-gate'), {
        cwd: repoDir,
        tool_name: 'Write',
        tool_input: { path: scopePath },
      });
      if (!/"permission"\s*:\s*"allow"/.test(out)) {
        return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('step0-gate allows code edit when intent filled', () => {
    const repoDir = join(HOME, '.cd-verify-step0-allow');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(join(repoDir, 'package.json'), '{}');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix foo',
        intent: 'Fix the foo module',
        decomposition: [],
        verifications: [],
        files: [],
        acceptance: 'tests pass',
      }));
      const out = runHook(hook('step0-gate'), {
        cwd: repoDir,
        tool_name: 'StrReplace',
        tool_input: { path: join(repoDir, 'src/foo.ts') },
      });
      if (!/"permission"\s*:\s*"allow"/.test(out)) {
        return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('step0-gate denies second file without decomposition', () => {
    const repoDir = join(HOME, '.cd-verify-step0-decomp');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(join(repoDir, 'package.json'), '{}');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix foo and bar',
        intent: 'Fix foo and bar modules',
        decomposition: [],
        verifications: [],
        files: ['src/foo.ts'],
        acceptance: 'tests pass',
      }));
      const out = runHook(hook('step0-gate'), {
        cwd: repoDir,
        tool_name: 'Write',
        tool_input: { path: join(repoDir, 'src/bar.ts') },
      });
      if (!/"permission"\s*:\s*"deny"/.test(out)) {
        return { ok: false, detail: `expected deny, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('step0-gate allows second file when decomposition declared', () => {
    const repoDir = join(HOME, '.cd-verify-step0-decomp-ok');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(join(repoDir, 'package.json'), '{}');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix foo and bar',
        intent: 'Fix foo and bar modules',
        decomposition: [{ step: 1, subtask: 'foo', expected_files: ['src/foo.ts'] }, { step: 2, subtask: 'bar', expected_files: ['src/bar.ts'] }],
        verifications: [],
        files: ['src/foo.ts'],
        acceptance: 'tests pass',
      }));
      const out = runHook(hook('step0-gate'), {
        cwd: repoDir,
        tool_name: 'Write',
        tool_input: { path: join(repoDir, 'src/bar.ts') },
      });
      if (!/"permission"\s*:\s*"allow"/.test(out)) {
        return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile writes .scope.json from the prompt', () => {
    const repoDir = join(HOME, '.cd-verify-precompile');
    const scopePath = join(repoDir, '.scope.json');
    const defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.';
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), { conversation_id: 'pc1', cwd: repoDir, prompt: 'fix the sidebar' });
      if (!existsSync(scopePath)) return { ok: false, detail: '.scope.json was not created' };
      let s;
      try { s = JSON.parse(readFileSync(scopePath, 'utf8')); }
      catch { return { ok: false, detail: '.scope.json is not valid JSON' }; }
      if (s.prompt !== 'fix the sidebar') return { ok: false, detail: `prompt mismatch: ${s.prompt}` };
      if (s.intent !== '') return { ok: false, detail: `intent should be empty seed: ${JSON.stringify(s.intent)}` };
      if (!Array.isArray(s.files) || s.files.length !== 0) return { ok: false, detail: 'files[] should start empty' };
      if (!Array.isArray(s.decomposition) || s.decomposition.length !== 0) return { ok: false, detail: 'decomposition[] should start empty' };
      if (!Array.isArray(s.verifications) || s.verifications.length !== 0) return { ok: false, detail: 'verifications[] should start empty' };
      s.intent = 'Fix sidebar layout bug';
      s.files = ['src/Sidebar.tsx'];
      s.decomposition = [{ step: 1, subtask: 'fix layout', expected_files: ['src/Sidebar.tsx'] }];
      writeFileSync(scopePath, JSON.stringify(s), 'utf8');
      runHook(hook('intent-precompile'), { conversation_id: 'pc1', cwd: repoDir, prompt: 'now fix the sidebar padding too' });
      try { s = JSON.parse(readFileSync(scopePath, 'utf8')); }
      catch { return { ok: false, detail: '.scope.json corrupted on second prompt' }; }
      if (s.prompt !== 'now fix the sidebar padding too') return { ok: false, detail: `prompt not updated: ${s.prompt}` };
      if (s.intent !== 'Fix sidebar layout bug') return { ok: false, detail: `intent clobbered: ${s.intent}` };
      if (!Array.isArray(s.files) || s.files.length !== 1 || s.files[0] !== 'src/Sidebar.tsx') {
        return { ok: false, detail: `files[] not preserved: ${JSON.stringify(s.files)}` };
      }
      if (!Array.isArray(s.decomposition) || s.decomposition.length !== 1) {
        return { ok: false, detail: `decomposition[] not preserved on continuation: ${JSON.stringify(s.decomposition)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile normalizes legacy scope missing decomposition/verifications', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-legacy');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'old prompt',
        intent: 'Old intent',
        files: ['src/a.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      runHook(hook('intent-precompile'), { conversation_id: 'pc1l', cwd: repoDir, prompt: 'follow up question' });
      const s = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (s.prompt !== 'follow up question') return { ok: false, detail: `prompt not updated: ${s.prompt}` };
      if (!Array.isArray(s.decomposition)) return { ok: false, detail: 'decomposition[] not normalized' };
      if (!Array.isArray(s.verifications)) return { ok: false, detail: 'verifications[] not normalized' };
      if (s.decomposition.length !== 0 || s.verifications.length !== 0) {
        return { ok: false, detail: 'normalized arrays should be empty' };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile resets scope on topic change (automatic, no prefix)', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-topic');
    const scopePath = join(repoDir, '.scope.json');
    const defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.';
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), { conversation_id: 'pc1t', cwd: repoDir, prompt: 'fix the sidebar' });
      let s = JSON.parse(readFileSync(scopePath, 'utf8'));
      s.intent = 'Fix sidebar layout bug';
      s.files = ['src/Sidebar.tsx'];
      s.decomposition = [{ step: 1, subtask: 'fix layout', expected_files: ['src/Sidebar.tsx'] }];
      s.verifications = [{ step: 1, verdict: 'ACCEPT', diagnosis: '' }];
      s.acceptance = 'custom acceptance bar';
      writeFileSync(scopePath, JSON.stringify(s), 'utf8');
      runHook(hook('intent-precompile'), { conversation_id: 'pc1t', cwd: repoDir, prompt: 'refactor the auth middleware' });
      s = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (s.prompt !== 'refactor the auth middleware') return { ok: false, detail: `prompt mismatch: ${s.prompt}` };
      if (s.intent !== '') return { ok: false, detail: `intent not reset to empty: ${JSON.stringify(s.intent)}` };
      if (!Array.isArray(s.files) || s.files.length !== 0) return { ok: false, detail: `files[] not reset: ${JSON.stringify(s.files)}` };
      if (!Array.isArray(s.decomposition) || s.decomposition.length !== 0) return { ok: false, detail: `decomposition[] not reset: ${JSON.stringify(s.decomposition)}` };
      if (!Array.isArray(s.verifications) || s.verifications.length !== 0) return { ok: false, detail: `verifications[] not reset: ${JSON.stringify(s.verifications)}` };
      if (s.acceptance !== defaultAcceptance) return { ok: false, detail: `acceptance not reset: ${s.acceptance}` };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile skips hook-generated prompts', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-skip');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), { conversation_id: 'pc2', cwd: repoDir, prompt: 'fix the sidebar' });
      let before = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (before.prompt !== 'fix the sidebar') return { ok: false, detail: 'seed failed' };
      runHook(hook('intent-precompile'), { conversation_id: 'pc2', cwd: repoDir, prompt: 'FINAL REVIEW (end of implementation) - audit everything' });
      let after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (after.prompt !== 'fix the sidebar') return { ok: false, detail: 'hook-generated prompt overwrote prompt' };
      runHook(hook('intent-precompile'), { conversation_id: 'pc2', cwd: repoDir, prompt: 'VERIFY MILESTONE step 1 of 2' });
      after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (after.prompt !== 'fix the sidebar') return { ok: false, detail: 'VERIFY MILESTONE header overwrote prompt' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile skips Cursor Plan Mode payloads', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-plan-mode');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), {
        conversation_id: 'pcplan1',
        cwd: repoDir,
        composer_mode: 'plan',
        prompt: 'investigate the auth flow and write a plan',
      });
      if (existsSync(scopePath)) return { ok: false, detail: '.scope.json was created for Plan Mode' };
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix the sidebar',
        intent: 'Fix sidebar layout',
        decomposition: [],
        verifications: [],
        files: ['src/Sidebar.tsx'],
        acceptance: 'tests pass',
      }), 'utf8');
      runHook(hook('intent-precompile'), {
        conversation_id: 'pcplan1',
        cwd: repoDir,
        mode: 'planning',
        prompt: 'create a detailed implementation plan',
      });
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (after.prompt !== 'fix the sidebar') return { ok: false, detail: `plan mode overwrote prompt: ${after.prompt}` };
      if (after.intent !== 'Fix sidebar layout') return { ok: false, detail: `plan mode clobbered intent: ${after.intent}` };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile skips obvious plan-only text but not implementation text', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-plan-text');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), { conversation_id: 'pcplan2', cwd: repoDir, prompt: 'write the plan first' });
      if (existsSync(scopePath)) return { ok: false, detail: '.scope.json was created for plan-only text' };
      runHook(hook('intent-precompile'), { conversation_id: 'pcplan2', cwd: repoDir, isPlanMode: 'false', prompt: 'implement the plan' });
      if (!existsSync(scopePath)) return { ok: false, detail: '.scope.json was not created for implementation text' };
      const s = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (s.prompt !== 'implement the plan') return { ok: false, detail: `wrong prompt after implementation text: ${s.prompt}` };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile stashes STEP 0 CONTRACT for scope-drain', () => {
    const cidv = 'npxvpc0';
    const repoDir = join(HOME, '.cd-verify-precompile-step0');
    const stashPath = join(pendingDir, `precompile-${cidv}.txt`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      rmBestEffort(stashPath);
      runHook(hook('intent-precompile'), { conversation_id: cidv, cwd: repoDir, prompt: 'fix the sidebar' });
      if (!existsSync(stashPath)) return { ok: false, detail: 'precompile stash not written' };
      const stash = readFileSync(stashPath, 'utf8');
      if (!stash.includes('STEP 0 CONTRACT')) return { ok: false, detail: 'stash missing STEP 0 CONTRACT header' };
      const delivered = runHook(hook('scope-drain'), { conversation_id: cidv });
      if (!delivered.includes('additional_context') || !delivered.includes('STEP 0 CONTRACT')) {
        return { ok: false, detail: `scope-drain did not deliver precompile stash: ${delivered.slice(0, 200)}` };
      }
      if (existsSync(stashPath)) return { ok: false, detail: 'precompile stash not one-shot' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(stashPath);
    }
  });

  check('milestone-verify emits reminder when step expected_files all touched', () => {
    const cidv = 'npxvmv1';
    const repoDir = join(HOME, '.cd-verify-mv1');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login',
        decomposition: [
          { step: 1, subtask: 'backend', expected_files: ['server/auth.ts', 'server/routes/login.ts'] },
          { step: 2, subtask: 'frontend', expected_files: ['src/login.tsx'] },
        ],
        verifications: [],
        files: ['server/auth.ts', 'server/routes/login.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, cwd: repoDir });
      if (!out.includes('additional_context') || !out.includes('VERIFY MILESTONE step 1')) {
        return { ok: false, detail: `expected reminder for step 1, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('milestone-verify emits DECOMPOSE on 1 file with empty decomposition', () => {
    const cidv = 'npxvmv2';
    const repoDir = join(HOME, '.cd-verify-mv2');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'typo fix',
        intent: '',
        decomposition: [],
        verifications: [],
        files: ['README.md'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, cwd: repoDir });
      if (!out.includes('additional_context') || !out.includes('DECOMPOSE')) {
        return { ok: false, detail: `expected DECOMPOSE nudge on 1 file, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('milestone-verify silent when no files touched', () => {
    const cidv = 'npxvmv2b';
    const repoDir = join(HOME, '.cd-verify-mv2b');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'typo fix',
        intent: '',
        decomposition: [],
        verifications: [],
        files: [],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, cwd: repoDir });
      if (out.includes('additional_context') || out.includes('DECOMPOSE') || out.includes('VERIFY MILESTONE')) {
        return { ok: false, detail: `should be silent with zero files, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('milestone-verify scrapes ACCEPT step N from transcript and writes verifications[N]', () => {
    const cidv = 'npxvmv3';
    const repoDir = join(HOME, '.cd-verify-mv3');
    const scopePath = join(repoDir, '.scope.json');
    const transcriptPath = join(HOME, '.cursor', '.hooks-pending', `transcript-${cidv}.jsonl`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      mkdirSync(dirname(transcriptPath), { recursive: true });
      // Plant a transcript with one assistant turn containing the verdict.
      // The hook walks backward looking for assistant role + verdict pattern.
      const rec = { role: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ACCEPT step 1: backend wired correctly.' }] } };
      writeFileSync(transcriptPath, JSON.stringify(rec) + '\n', 'utf8');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login',
        decomposition: [
          { step: 1, subtask: 'backend', expected_files: ['server/auth.ts'] },
        ],
        verifications: [],
        files: ['server/auth.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, transcript_path: transcriptPath, cwd: repoDir });
      // After scraping, the verdict is recorded AND no reminder should fire
      // (the now-verified step satisfies the unverified-milestone check).
      if (out.includes('VERIFY MILESTONE')) {
        return { ok: false, detail: 'reminder fired after verdict was scraped' };
      }
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (!Array.isArray(after.verifications) || after.verifications.length !== 1) {
        return { ok: false, detail: `verdict not recorded: ${JSON.stringify(after.verifications)}` };
      }
      const v = after.verifications[0];
      if (v.step !== 1 || v.verdict !== 'ACCEPT') {
        return { ok: false, detail: `verdict mismatch: ${JSON.stringify(v)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(transcriptPath);
    }
  });

  check('milestone-verify auto-writes PENDING when expected_files all touched', () => {
    const cidv = 'npxvmvp';
    const repoDir = join(HOME, '.cd-verify-mvp');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login',
        decomposition: [
          { step: 1, subtask: 'backend', expected_files: ['server/auth.ts'] },
        ],
        verifications: [],
        files: ['server/auth.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, cwd: repoDir });
      if (!out.includes('VERIFY MILESTONE')) {
        return { ok: false, detail: `expected reminder, got: ${out.slice(0, 200)}` };
      }
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (!Array.isArray(after.verifications) || after.verifications.length !== 1) {
        return { ok: false, detail: `PENDING not recorded: ${JSON.stringify(after.verifications)}` };
      }
      const v = after.verifications[0];
      if (v.step !== 1 || v.verdict !== 'PENDING') {
        return { ok: false, detail: `expected step 1 PENDING, got: ${JSON.stringify(v)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('milestone-verify scrapes loosened phrasings (e.g. "step 1 looks good")', () => {
    const cidv = 'npxvmvl';
    const repoDir = join(HOME, '.cd-verify-mvl');
    const scopePath = join(repoDir, '.scope.json');
    const transcriptPath = join(pendingDir, `transcript-${cidv}.jsonl`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      mkdirSync(dirname(transcriptPath), { recursive: true });
      // Casual phrasing that the OLD regex missed — the loosened set must catch it.
      const rec = { role: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'step 1 looks good, wiring is correct.' }] } };
      writeFileSync(transcriptPath, JSON.stringify(rec) + '\n', 'utf8');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login',
        decomposition: [{ step: 1, subtask: 'backend', expected_files: ['server/auth.ts'] }],
        verifications: [],
        files: ['server/auth.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, transcript_path: transcriptPath, cwd: repoDir });
      // After scraping, the verdict is recorded as ACCEPT and no PENDING remains.
      if (out.includes('VERIFY MILESTONE')) {
        return { ok: false, detail: 'reminder fired after loose verdict was scraped' };
      }
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      const v = after.verifications && after.verifications[0];
      if (!v || v.step !== 1 || v.verdict !== 'ACCEPT') {
        return { ok: false, detail: `expected ACCEPT step 1, got: ${JSON.stringify(after.verifications)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(transcriptPath);
    }
  });

  check('scope-git-sweep catches a Shell-written file into files[]', () => {
    const cidv = 'npxvsgs';
    const sandbox = join(HOME, '.cd-verify-sgs');
    const scopePath = join(sandbox, '.scope.json');
    const sandboxEnv = { ...process.env, CURSORDOCTRINE_HOME: HOME, HOME, USERPROFILE: HOME };
    try {
      rmSync(sandbox, { recursive: true, force: true });
      mkdirSync(sandbox, { recursive: true });
      const git = (args) => spawnSync('git', ['-C', sandbox, ...args], {
        encoding: 'utf8', windowsHide: true,
        env: { ...sandboxEnv, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      if (git(['init', '-q']).status !== 0) return { ok: false, detail: 'git init failed' };
      writeFileSync(join(sandbox, 'README.md'), 'init\n');
      git(['add', 'README.md']);
      if (git(['commit', '-q', '-m', 'init']).status !== 0) return { ok: false, detail: 'git commit failed' };

      // Seed .scope.json with empty files[].
      writeFileSync(scopePath, JSON.stringify({
        prompt: 't', intent: 't', decomposition: [], verifications: [], files: [], acceptance: 'tests pass',
      }));

      // Simulate a Shell-tool write: create a new untracked file via plain
      // Set-Content-equivalent (no afterFileEdit). The hook must catch it via
      // git diff --name-only + ls-files --others.
      mkdirSync(join(sandbox, 'src'), { recursive: true });
      writeFileSync(join(sandbox, 'src', 'generated.ts'), 'shell-written\n');

      const payload = JSON.stringify({ conversation_id: cidv, cwd: sandbox, tool_name: 'Shell' });
      const r = spawnSync(platform === 'windows' ? 'pwsh.exe' : 'bash',
        platform === 'windows'
          ? ['-NoProfile', '-File', hook('scope-git-sweep')]
          : [hook('scope-git-sweep')],
        { input: payload, encoding: 'utf8', timeout: 20000, windowsHide: true, env: sandboxEnv });
      if (r.error) return { ok: false, detail: `spawn error: ${r.error.message}` };

      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      // Path normalization is forward-slash relative; accept either form.
      const hit = (after.files || []).some((f) => String(f).replace(/\\/g, '/') === 'src/generated.ts');
      if (!hit) return { ok: false, detail: `src/generated.ts not in files[]: ${JSON.stringify(after.files)}` };
      return true;
    } finally {
      rmBestEffort(sandbox, { recursive: true, force: true });
    }
  });

  check('scope-git-sweep ignores Shell-written Cursor plan files', () => {
    const cidv = 'npxvsgsplan';
    const sandbox = join(HOME, '.cd-verify-sgs-plan');
    const scopePath = join(sandbox, '.scope.json');
    const sandboxEnv = { ...process.env, CURSORDOCTRINE_HOME: HOME, HOME, USERPROFILE: HOME };
    try {
      rmSync(sandbox, { recursive: true, force: true });
      mkdirSync(sandbox, { recursive: true });
      const git = (args) => spawnSync('git', ['-C', sandbox, ...args], {
        encoding: 'utf8', windowsHide: true,
        env: { ...sandboxEnv, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      if (git(['init', '-q']).status !== 0) return { ok: false, detail: 'git init failed' };
      writeFileSync(join(sandbox, 'README.md'), 'init\n');
      git(['add', 'README.md']);
      if (git(['commit', '-q', '-m', 'init']).status !== 0) return { ok: false, detail: 'git commit failed' };
      writeFileSync(scopePath, JSON.stringify({
        prompt: 't', intent: 't', decomposition: [], verifications: [], files: [], acceptance: 'tests pass',
      }));
      mkdirSync(join(sandbox, '.cursor', 'plans'), { recursive: true });
      writeFileSync(join(sandbox, '.cursor', 'plans', 'next.md'), 'plan\n');

      const payload = JSON.stringify({ conversation_id: cidv, cwd: sandbox, tool_name: 'Shell' });
      const r = spawnSync(platform === 'windows' ? 'pwsh.exe' : 'bash',
        platform === 'windows'
          ? ['-NoProfile', '-File', hook('scope-git-sweep')]
          : [hook('scope-git-sweep')],
        { input: payload, encoding: 'utf8', timeout: 20000, windowsHide: true, env: sandboxEnv });
      if (r.error) return { ok: false, detail: `spawn error: ${r.error.message}` };

      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if ((after.files || []).length !== 0) return { ok: false, detail: `plan file entered files[]: ${JSON.stringify(after.files)}` };
      return true;
    } finally {
      rmBestEffort(sandbox, { recursive: true, force: true });
    }
  });

  check('intent-anchor fires on empty intent, silent when no new files, re-fires on new files', () => {
    const cidv = 'npxvia';
    const repoDir = join(HOME, '.cd-verify-ia');
    const scopePath = join(repoDir, '.scope.json');
    const flagPath = join(pendingDir, `intent-anchored-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      rmBestEffort(flagPath);
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: '',
        decomposition: [],
        verifications: [],
        files: ['src/login.tsx'],
        acceptance: 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.',
      }), 'utf8');
      // First fire: 1 file, intent empty → should nudge.
      const first = runHook(hook('intent-anchor'), { conversation_id: cidv, cwd: repoDir });
      if (!first.includes('additional_context') || !first.includes('INTENT ANCHOR')) {
        return { ok: false, detail: `should fire on empty intent, got: ${first.slice(0, 200)}` };
      }
      if (!existsSync(flagPath)) {
        return { ok: false, detail: 'flag was not armed after first fire' };
      }
      // Second fire: same file count, intent still empty → should stay silent.
      const second = runHook(hook('intent-anchor'), { conversation_id: cidv, cwd: repoDir });
      if (second.includes('additional_context') || second.includes('INTENT ANCHOR')) {
        return { ok: false, detail: 'should stay silent when no new files since last nudge' };
      }
      // Third fire: a NEW file was added to files[], intent still empty → re-fire.
      const sj = JSON.parse(readFileSync(scopePath, 'utf8'));
      sj.files.push('src/auth.ts');
      writeFileSync(scopePath, JSON.stringify(sj), 'utf8');
      const third = runHook(hook('intent-anchor'), { conversation_id: cidv, cwd: repoDir });
      if (!third.includes('additional_context') || !third.includes('INTENT ANCHOR')) {
        return { ok: false, detail: 'should re-fire when new file added since last nudge' };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('intent-anchor silent when intent and acceptance already filled', () => {
    const cidv = 'npxvia2';
    const repoDir = join(HOME, '.cd-verify-ia2');
    const scopePath = join(repoDir, '.scope.json');
    const flagPath = join(pendingDir, `intent-anchored-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      rmBestEffort(flagPath);
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login form with rate limit',
        decomposition: [],
        verifications: [],
        files: ['src/login.tsx'],
        acceptance: 'npm run test:e2e passes; rate limit holds at 5/min',
      }), 'utf8');
      const out = runHook(hook('intent-anchor'), { conversation_id: cidv, cwd: repoDir });
      if (out.includes('additional_context') || out.includes('INTENT ANCHOR')) {
        return { ok: false, detail: `should stay silent when contract is filled, got: ${out.slice(0, 200)}` };
      }
      if (!existsSync(flagPath)) {
        return { ok: false, detail: 'flag should still be armed (so we never bug this cid again)' };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('scope-refresh prunes <TODO> entries on re-edit of already-recorded file', () => {
    const cidv = 'npxvprune';
    const repoDir = join(HOME, '.cd-verify-prune');
    const scopePath = join(repoDir, '.scope.json');
    const stashPath = join(pendingDir, `scope-${cidv}.txt`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      rmBestEffort(stashPath);
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix sidebar',
        intent: 'fix layout',
        decomposition: [],
        verifications: [],
        // Sidebar.tsx is real and will be re-edited below. <TODO: fill> and
        // the empty string are placeholders the agent may have seeded at
        // Step 0 — these MUST be pruned even when the edited file is already
        // present, because pre-fix the write-back was gated on "adding a new
        // file" and the garbage survived forever. The third bogus entry is an
        // absolute path that the hook does NOT prune (agent-owned declaration).
        files: ['src/Sidebar.tsx', '<TODO: fill>', '', 'src/other.tsx'],
        acceptance: 'tests pass',
      }), 'utf8');
      // Re-edit src/Sidebar.tsx (already in the list). Pre-fix, the placeholder
      // entries stayed forever because write-back was gated on "adding a new file."
      runHook(hook('scope-refresh'), { conversation_id: cidv, cwd: repoDir, file_path: join(repoDir, 'src/Sidebar.tsx') });
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (!Array.isArray(after.files)) return { ok: false, detail: 'files[] missing' };
      // Sidebar.tsx (kept) + other.tsx (kept, agent declaration) = 2. <TODO> and '' pruned.
      if (after.files.length !== 2) {
        return { ok: false, detail: `expected 2 entries (Sidebar + other), got ${after.files.length}: ${JSON.stringify(after.files)}` };
      }
      if (after.files.some((f) => typeof f === 'string' && (f.trim() === '' || /^\s*<TODO/.test(f)))) {
        return { ok: false, detail: `placeholder/blank survived: ${JSON.stringify(after.files)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(stashPath);
    }
  });

  check('permission gate allows `git status`', () =>
    /"permission"\s*:\s*"allow"/.test(runHook(hook('permission-gate'), { command: 'git status' })));

  check('scope refresh stashes + scope drain delivers .scope.json', () => {
    // Plant a .scope.json in a fake repo root, fire scope-refresh with an edit
    // payload, then fire scope-drain and confirm the contract is delivered as
    // additional_context. Then fire scope-drain again and confirm it's quiet
    // (one-shot).
    const cidv = 'npxvscope';
    const repoDir = join(HOME, '.cd-verify-scope');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'user asked for sidebar fix',
        intent: 'test intent',
        files: ['a.ts', 'b.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      runHook(hook('scope-refresh'), { conversation_id: cidv, cwd: repoDir, file_path: join(repoDir, 'a.ts') });
      const delivered = runHook(hook('scope-drain'), { conversation_id: cidv });
      const secondDrain = runHook(hook('scope-drain'), { conversation_id: cidv });
      if (!delivered.includes('additional_context') || !delivered.includes('test intent')) {
        return { ok: false, detail: 'scope-drain did not deliver the contract' };
      }
      if (secondDrain.includes('additional_context')) {
        return { ok: false, detail: 'scope-drain delivered twice (not one-shot)' };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(join(pendingDir, `scope-${cidv}.txt`));
    }
  });

  check('scope refresh ignores saved Cursor plan files', () => {
    const cidv = 'npxvscopeplan';
    const repoDir = join(HOME, '.cd-verify-scope-plan');
    const scopePath = join(repoDir, '.scope.json');
    const stashPath = join(pendingDir, `scope-${cidv}.txt`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(join(repoDir, '.cursor', 'plans'), { recursive: true });
      rmBestEffort(stashPath);
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix sidebar',
        intent: 'Fix sidebar',
        decomposition: [],
        verifications: [],
        files: [],
        acceptance: 'tests pass',
      }), 'utf8');
      runHook(hook('scope-refresh'), {
        conversation_id: cidv,
        cwd: repoDir,
        file_path: join(repoDir, '.cursor', 'plans', 'fix-sidebar.md'),
      });
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if ((after.files || []).length !== 0) return { ok: false, detail: `plan file entered files[]: ${JSON.stringify(after.files)}` };
      if (existsSync(stashPath)) return { ok: false, detail: 'scope reminder was stashed for a plan file' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(stashPath);
    }
  });

  check('scope refresh stays silent when no .scope.json exists', () => {
    const cidv = 'npxvscope2';
    const repoDir = join(HOME, '.cd-verify-noscope');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('scope-refresh'), { conversation_id: cidv, cwd: repoDir, file_path: join(repoDir, 'a.ts') });
      const drain = runHook(hook('scope-drain'), { conversation_id: cidv });
      if (drain.includes('additional_context')) {
        return { ok: false, detail: 'scope-drain emitted without a .scope.json' };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(join(pendingDir, `scope-${cidv}.txt`));
    }
  });

  check('final review fires once when files changed, then goes quiet (no further edits)', () => {
    const cidv = 'npxvfr';
    const repoDir = join(HOME, '.cd-verify-repo');
    const filePath = join(repoDir, 'dummy.ts');
    const flagPath = join(pendingDir, `reviewed-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(filePath, 'original\n', 'utf8');
      const git = (args) => spawnSync('git', ['-C', repoDir, ...args], {
        encoding: 'utf8', windowsHide: true, env: { ...process.env, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      let r = git(['init', '-q']);
      if (r.status !== 0) return { ok: false, detail: `git init failed: ${(r.stderr || '').trim()}` };
      git(['add', 'dummy.ts']);
      r = git(['commit', '-q', '-m', 'init']);
      if (r.status !== 0) return { ok: false, detail: `git commit failed: ${(r.stderr || '').trim()}` };
      writeFileSync(filePath, 'changed\n', 'utf8');
      rmBestEffort(flagPath);

      const first = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir });
      if (!first.includes('followup_message')) return { ok: false, detail: 'no followup_message on first stop' };
      // No further edits → diff count unchanged → second stop should be quiet (accept).
      const second = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir, loop_count: 1 });
      if (second.includes('followup_message')) return { ok: false, detail: 'review re-fired when diff unchanged (should be accept)' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('final review recovers from orphaned reviewed flag', () => {
    const cidv = 'npxvfr3';
    const repoDir = join(HOME, '.cd-verify-orphan');
    const filePath = join(repoDir, 'dummy.ts');
    const flagPath = join(pendingDir, `reviewed-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(filePath, 'original\n', 'utf8');
      const git = (args) => spawnSync('git', ['-C', repoDir, ...args], {
        encoding: 'utf8', windowsHide: true, env: { ...process.env, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      git(['init', '-q']);
      git(['add', 'dummy.ts']);
      git(['commit', '-q', '-m', 'init']);
      writeFileSync(filePath, 'changed\n', 'utf8');
      // Plant an orphaned flag (stale count from a session that died).
      writeFileSync(flagPath, '0', 'utf8');

      const out = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir, loop_count: 0 });
      if (!out.includes('followup_message')) return { ok: false, detail: 'orphaned flag suppressed review' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('final review stays quiet when no files changed', () => {
    const cidv = 'npxvfr2';
    const repoDir = join(HOME, '.cd-verify-clean');
    const filePath = join(repoDir, 'dummy.ts');
    const flagPath = join(pendingDir, `reviewed-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(filePath, 'original\n', 'utf8');
      const git = (args) => spawnSync('git', ['-C', repoDir, ...args], {
        encoding: 'utf8', windowsHide: true, env: { ...process.env, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      git(['init', '-q']);
      git(['add', 'dummy.ts']);
      git(['commit', '-q', '-m', 'init']);
      rmBestEffort(flagPath);
      const out = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir });
      if (out.includes('followup_message')) return { ok: false, detail: 'review fired on a clean repo (no diff)' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('final review stays quiet when only Cursor plan files changed', () => {
    const cidv = 'npxvfrplan';
    const repoDir = join(HOME, '.cd-verify-plan-only');
    const flagPath = join(pendingDir, `reviewed-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(join(repoDir, '.cursor', 'plans'), { recursive: true });
      const git = (args) => spawnSync('git', ['-C', repoDir, ...args], {
        encoding: 'utf8', windowsHide: true, env: { ...process.env, GIT_AUTHOR_NAME: 'v', GIT_AUTHOR_EMAIL: 'a@b.c', GIT_COMMITTER_NAME: 'v', GIT_COMMITTER_EMAIL: 'a@b.c' },
      });
      git(['init', '-q']);
      writeFileSync(join(repoDir, 'README.md'), 'init\n', 'utf8');
      git(['add', 'README.md']);
      git(['commit', '-q', '-m', 'init']);
      writeFileSync(join(repoDir, '.cursor', 'plans', 'fix.md'), 'plan\n', 'utf8');
      rmBestEffort(flagPath);
      const out = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir, composer_mode: 'plan' });
      if (out.includes('followup_message')) return { ok: false, detail: 'review fired for saved plan-only change' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  check('doctrine injection emits additional_context', () =>
    runHook(join(cursorDst, injectName), {}).includes('additional_context'));

  check('final review fires for non-git project via .scope.json fallback', () => {
    const cidv = 'npxvfrng';
    const repoDir = join(HOME, '.cd-verify-nogit');
    const scopePath = join(repoDir, '.scope.json');
    const flagPath = join(pendingDir, `reviewed-${cidv}.flag`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      // NO git init — this is a non-git project. Plant a .scope.json with files.
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'fix the bug',
        intent: 'Fix null pointer in auth',
        decomposition: [],
        verifications: [],
        files: ['src/auth.ts', 'src/utils.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      rmBestEffort(flagPath);
      const out = runHook(hook('final-review'), { conversation_id: cidv, status: 'completed', cwd: repoDir });
      if (!out.includes('followup_message')) return { ok: false, detail: 'review did not fire for non-git project' };
      if (!out.includes('src/auth.ts')) return { ok: false, detail: 'files[] from scope.json not in review' };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
      rmBestEffort(flagPath);
    }
  });

  const py = pythonCmd();
  const scanner = join(skillDst, 'scripts', 'scan_slop.py');
  let scannerOk = false;
  if (py && existsSync(scanner)) {
    const r = spawnSync(py, [scanner, '--help'], { encoding: 'utf8', timeout: 20000, windowsHide: true });
    scannerOk = !r.error && /usage/i.test(`${r.stdout || ''}${r.stderr || ''}`);
  }
  console.log(`  ${scannerOk ? ' ok ' : 'warn'}  anti-slop scanner --help${scannerOk ? '' : ' — unavailable (final review falls back to the checklist)'}`);

  check('sweep runs and emits a structured report when scanner is available', () => {
    if (!scannerOk) return true;
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
    ['reexport_slop', 'BARE RE-EXPORTS', 'export ... from lines that ship nothing of their own'],
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

  const removed = removeOurPack();

  if (existsSync(hooksJsonDst)) {
    try {
      JSON.parse(readFileSync(hooksJsonDst, 'utf8'));
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
  console.log(`cursordoctrine ${pkg.version} — hooks for Cursor: doctrine at start, scope re-injected per edit, gate on shell, review at stop

Usage
  npx cursordoctrine <command>

Commands
  install      Install the hook pack, doctrine, and anti-slop skill into $HOME.
               Removes any prior cursordoctrine install first, then writes fresh.
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
  INTENT_PRECOMPILE_ENFORCE=0  .scope.json auto-write on prompt off
  SCOPE_REFRESH_ENFORCE=0      per-edit re-injection + files[] recording off
  MILESTONE_VERIFY_ENFORCE=0   mid-session milestone verifier off (doctrine-ultra)
  INTENT_ANCHOR_ENFORCE=0      contract nudge off
  FINAL_REVIEW_ENFORCE=0       final review off

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
