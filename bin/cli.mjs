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
import { verify as runVerify } from './verify.mjs';

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
          entry.command = entry.command.replace(/-File "~\/([^"]+)"/g, `-File "${homeFwd}/$1"`);
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

// package.json is load-bearing: step0-gate gates on is_project_root, so the
// sandbox must look like a project or the gate short-circuits before the scope check.
function withScopeSandbox(name, scopeObj, fn) {
  const repoDir = join(HOME, name);
  const scopePath = join(repoDir, '.scope.json');
  try {
    rmSync(repoDir, { recursive: true, force: true });
    mkdirSync(repoDir, { recursive: true });
    writeFileSync(join(repoDir, 'package.json'), '{}');
    writeFileSync(scopePath, JSON.stringify(scopeObj), 'utf8');
    return fn(repoDir, scopePath);
  } finally {
    rmBestEffort(repoDir, { recursive: true, force: true });
  }
}
function verify() {
  runVerify({
    HOME,
    platform,
    pkg,
    hooksDst,
    hooksJsonDst,
    pendingDir,
    cursorDst,
    injectName,
    payload,
    pkgRoot,
    skillDst,
    runHook,
    withScopeSandbox,
    ourKeys,
    STALE_HOOK_FILES,
    rmBestEffort,
    mergeHooks,
    pythonCmd,
    keyOf,
  });
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
