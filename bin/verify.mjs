import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';

export function verify(ctx) {
  const {
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
  } = ctx;

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

  check('step0-gate denies code edit when intent empty', () =>
    withScopeSandbox('.cd-verify-step0-empty', {
      prompt: 'fix foo', intent: '', decomposition: [], verifications: [], files: [], acceptance: 'tests pass',
    }, (repoDir) => {
      const out = runHook(hook('step0-gate'), { cwd: repoDir, tool_name: 'Write', tool_input: { path: join(repoDir, 'src/foo.ts') } });
      if (!/"permission"\s*:\s*"deny"/.test(out)) return { ok: false, detail: `expected deny, got: ${out.slice(0, 200)}` };
      return true;
    }));

  check('step0-gate allows .scope.json write when intent empty', () =>
    withScopeSandbox('.cd-verify-step0-scope', {
      prompt: 'fix foo', intent: '', decomposition: [], verifications: [], files: [], acceptance: 'tests pass',
    }, (repoDir, scopePath) => {
      const out = runHook(hook('step0-gate'), { cwd: repoDir, tool_name: 'Write', tool_input: { path: scopePath } });
      if (!/"permission"\s*:\s*"allow"/.test(out)) return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      return true;
    }));

  check('step0-gate allows code edit when intent filled', () =>
    withScopeSandbox('.cd-verify-step0-allow', {
      prompt: 'fix foo', intent: 'Fix the foo module', decomposition: [], verifications: [], files: [], acceptance: 'tests pass',
    }, (repoDir) => {
      const out = runHook(hook('step0-gate'), { cwd: repoDir, tool_name: 'StrReplace', tool_input: { path: join(repoDir, 'src/foo.ts') } });
      if (!/"permission"\s*:\s*"allow"/.test(out)) return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      return true;
    }));

  check('step0-gate denies second file without decomposition', () =>
    withScopeSandbox('.cd-verify-step0-decomp', {
      prompt: 'fix foo and bar', intent: 'Fix foo and bar modules', decomposition: [], verifications: [], files: ['src/foo.ts'], acceptance: 'tests pass',
    }, (repoDir) => {
      const out = runHook(hook('step0-gate'), { cwd: repoDir, tool_name: 'Write', tool_input: { path: join(repoDir, 'src/bar.ts') } });
      if (!/"permission"\s*:\s*"deny"/.test(out)) return { ok: false, detail: `expected deny, got: ${out.slice(0, 200)}` };
      return true;
    }));

  check('step0-gate allows second file when decomposition declared', () =>
    withScopeSandbox('.cd-verify-step0-decomp-ok', {
      prompt: 'fix foo and bar', intent: 'Fix foo and bar modules',
      decomposition: [{ step: 1, subtask: 'foo', expected_files: ['src/foo.ts'] }, { step: 2, subtask: 'bar', expected_files: ['src/bar.ts'] }],
      verifications: [], files: ['src/foo.ts'], acceptance: 'tests pass',
    }, (repoDir) => {
      const out = runHook(hook('step0-gate'), { cwd: repoDir, tool_name: 'Write', tool_input: { path: join(repoDir, 'src/bar.ts') } });
      if (!/"permission"\s*:\s*"allow"/.test(out)) return { ok: false, detail: `expected allow, got: ${out.slice(0, 200)}` };
      return true;
    }));

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

  check('intent-precompile resets scope on /new prefix', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-new');
    const scopePath = join(repoDir, '.scope.json');
    const defaultAcceptance = 'Biome --error-on-warnings + Semgrep --config auto --error pass clean; typecheck/build passes; the described problem no longer reproduces.';
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), { conversation_id: 'pc1n', cwd: repoDir, prompt: 'fix the sidebar' });
      let s = JSON.parse(readFileSync(scopePath, 'utf8'));
      s.intent = 'Fix sidebar layout bug';
      s.files = ['src/Sidebar.tsx'];
      s.decomposition = [{ step: 1, subtask: 'fix layout', expected_files: ['src/Sidebar.tsx'] }];
      s.verifications = [{ step: 1, verdict: 'ACCEPT', diagnosis: '' }];
      s.acceptance = 'custom acceptance bar';
      writeFileSync(scopePath, JSON.stringify(s), 'utf8');
      runHook(hook('intent-precompile'), { conversation_id: 'pc1n', cwd: repoDir, prompt: '/new fix the bug' });
      s = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (s.prompt !== 'fix the bug') return { ok: false, detail: `prompt not stripped: ${s.prompt}` };
      if (s.intent !== '') return { ok: false, detail: `intent not reset: ${JSON.stringify(s.intent)}` };
      if (!Array.isArray(s.files) || s.files.length !== 0) return { ok: false, detail: `files[] not reset: ${JSON.stringify(s.files)}` };
      if (!Array.isArray(s.decomposition) || s.decomposition.length !== 0) return { ok: false, detail: `decomposition[] not reset` };
      if (s.acceptance !== defaultAcceptance) return { ok: false, detail: `acceptance not reset: ${s.acceptance}` };
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('intent-precompile resets scope on unicode topic change', () => {
    const repoDir = join(HOME, '.cd-verify-precompile-unicode');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      runHook(hook('intent-precompile'), {
        conversation_id: 'pc1u',
        cwd: repoDir,
        prompt: 'fix the sidebar padding margins borders',
      });
      let s = JSON.parse(readFileSync(scopePath, 'utf8'));
      s.intent = 'Fix sidebar layout';
      s.files = ['src/Sidebar.tsx'];
      writeFileSync(scopePath, JSON.stringify(s), 'utf8');
      runHook(hook('intent-precompile'), {
        conversation_id: 'pc1u',
        cwd: repoDir,
        prompt: '修复 身份 验证 中间件 重构 工作',
      });
      s = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (s.intent !== '') return { ok: false, detail: `intent not reset on unicode topic change: ${JSON.stringify(s.intent)}` };
      if (!Array.isArray(s.files) || s.files.length !== 0) return { ok: false, detail: `files[] not reset: ${JSON.stringify(s.files)}` };
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

  check('milestone-verify silent on 1 file with empty decomposition', () => {
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
      if (out.includes('additional_context') || out.includes('DECOMPOSE')) {
        return { ok: false, detail: `should be silent on 1-file trivial task, got: ${out.slice(0, 200)}` };
      }
      return true;
    } finally {
      rmBestEffort(repoDir, { recursive: true, force: true });
    }
  });

  check('milestone-verify emits DECOMPOSE on 2 files with empty decomposition', () => {
    const cidv = 'npxvmv2c';
    const repoDir = join(HOME, '.cd-verify-mv2c');
    const scopePath = join(repoDir, '.scope.json');
    try {
      rmBestEffort(join(pendingDir, `decompose-${cidv}.flag`));
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'multi fix',
        intent: '',
        decomposition: [],
        verifications: [],
        files: ['README.md', 'src/a.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, cwd: repoDir });
      if (!out.includes('additional_context') || !out.includes('DECOMPOSE')) {
        return { ok: false, detail: `expected DECOMPOSE nudge on 2 files, got: ${out.slice(0, 200)}` };
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

  check('milestone-verify upgrades an existing PENDING verdict to ACCEPT when the transcript holds the matching verdict', () => {
    const cidv = 'npxvmvu';
    const repoDir = join(HOME, '.cd-verify-mvu');
    const scopePath = join(repoDir, '.scope.json');
    const transcriptPath = join(HOME, '.cursor', '.hooks-pending', `transcript-${cidv}.jsonl`);
    try {
      rmSync(repoDir, { recursive: true, force: true });
      mkdirSync(repoDir, { recursive: true });
      mkdirSync(dirname(transcriptPath), { recursive: true });
      // Seed an auto-PENDING (as a prior milestone-verify run would write), then
      // plant a transcript where the agent emits the matching ACCEPT. Regression:
      // the Phase 1 guard used to key on ANY recorded verdict (incl. PENDING), so
      // the scraped ACCEPT was dropped and PENDING stuck — contradicting the
      // doctrine's "upgraded to ACCEPT/REVISE from chat" promise.
      const rec = { role: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ACCEPT step 1: backend wired correctly.' }] } };
      writeFileSync(transcriptPath, JSON.stringify(rec) + '\n', 'utf8');
      writeFileSync(scopePath, JSON.stringify({
        prompt: 'add login',
        intent: 'Add JWT login',
        decomposition: [
          { step: 1, subtask: 'backend', expected_files: ['server/auth.ts'] },
        ],
        verifications: [{ step: 1, verdict: 'PENDING', diagnosis: 'auto: all expected_files touched' }],
        files: ['server/auth.ts'],
        acceptance: 'tests pass',
      }), 'utf8');
      const out = runHook(hook('milestone-verify'), { conversation_id: cidv, transcript_path: transcriptPath, cwd: repoDir });
      if (out.includes('VERIFY MILESTONE')) {
        return { ok: false, detail: 'reminder fired after PENDING was upgraded to ACCEPT' };
      }
      const after = JSON.parse(readFileSync(scopePath, 'utf8'));
      if (!Array.isArray(after.verifications) || after.verifications.length !== 1) {
        return { ok: false, detail: `expected single upgraded verdict, got: ${JSON.stringify(after.verifications)}` };
      }
      const v = after.verifications[0];
      if (v.step !== 1 || v.verdict !== 'ACCEPT') {
        return { ok: false, detail: `PENDING did not upgrade to ACCEPT: ${JSON.stringify(v)}` };
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

      const stampPath = join(HOME, '.cursor', '.hooks-pending', `session-start-${cidv}.txt`);
      mkdirSync(dirname(stampPath), { recursive: true });
      writeFileSync(stampPath, new Date().toISOString(), 'utf8');

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
      const stampPath = join(HOME, '.cursor', '.hooks-pending', `session-start-${cidv}.txt`);
      mkdirSync(dirname(stampPath), { recursive: true });
      writeFileSync(stampPath, new Date().toISOString(), 'utf8');
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
