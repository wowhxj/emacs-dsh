import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { inspect, shutdown } from '../emacs-dsh-host.mjs';
const repo = fileURLToPath(new URL('..', import.meta.url));
const script = fileURLToPath(new URL('./native-host-child.el', import.meta.url));
const fake = fileURLToPath(new URL('./fake-host.mjs', import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 18000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await predicate(); if (value) return value; await sleep(30); }
  throw new Error('Native Host test deadline exceeded');
}
function client(root, mode, real = false, executable = '') {
  assert.ok(process.env.EMACS_DSH_TEST_MARKDOWN, 'Set EMACS_DSH_TEST_MARKDOWN');
  assert.ok(process.env.EMACS_DSH_TEST_WEBSOCKET, 'Set EMACS_DSH_TEST_WEBSOCKET');
  const child = spawn(process.env.EMACS || 'emacs', ['--batch', '-Q', '-L', repo,
    '-L', process.env.EMACS_DSH_TEST_MARKDOWN, '-L', process.env.EMACS_DSH_TEST_WEBSOCKET,
    '--eval', '(setq load-prefer-newer t)', '-l', script], {
    cwd: root, env: { ...process.env, DSH_HOME: path.join(root, real ? 'home' : 'fixture-home'),
      DSH_TELEMETRY_DISABLED: '1', DSH_EXECUTABLE: executable,
      ...(real ? { DEEPSEEK_API_KEY: 'fixture-not-a-real-model-key' } : {}),
      EMACS_DSH_SMOKE_ROOT: root, EMACS_DSH_SMOKE_MODE: mode, EMACS_DSH_SMOKE_REAL: real ? '1' : '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = ''; child.stdout.on('data', b => { log += b; }); child.stderr.on('data', b => { log += b; });
  return { child, log: () => log };
}
for (const real of [false, true]) for (const mode of ['normal', 'crash']) {
  test(`${real ? 'real DSH' : 'fixture'} Host survives actual Emacs ${mode} exit; fresh Emacs discovers without startup`, {
    skip: (real ? process.env.DSH_HOST_REAL : process.env.DSH_HOST_NATIVE) !== '1', timeout: 55000,
  }, async () => {
    const root = fs.mkdtempSync('/tmp/dsh-native-'); fs.chmodSync(root, 0o700);
    let wrapper = path.join(root, 'fixture-dsh');
    if (real) {
      wrapper = process.env.DSH_EXECUTABLE || (process.env.PATH || '').split(path.delimiter)
        .map(dir => path.join(dir, 'dsh')).find(file => fs.existsSync(file));
      assert.ok(wrapper && path.isAbsolute(wrapper), 'Installed DSH executable required');
    } else {
      // Fixed, generated fixture paths contain no shell metacharacters; argv is preserved.
      fs.writeFileSync(wrapper, `#!/bin/sh\nexec '${process.execPath}' '${fake}' "$@"\n`, { mode: 0o700 });
    }
    const options = { runtime: path.join(root, 'run'), home: path.join(root, real ? 'home' : 'fixture-home'), cwd: root,
      argv: [wrapper, 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'] };
    let first, second;
    try {
      first = client(root, mode, real, wrapper);
      await waitFor(() => {
        if (first.child.exitCode !== null && !fs.existsSync(path.join(root, 'armed'))) throw new Error(first.log());
        return fs.existsSync(path.join(root, 'armed'));
      });
      const before = await inspect(options);
      assert.equal(before.status, 'running');
      if (!real) await waitFor(() => fs.existsSync(path.join(options.home, 'ticks')));
      const ticks = !real && Number(fs.readFileSync(path.join(options.home, 'ticks')));
      const ended = first.child.exitCode !== null ? Promise.resolve([first.child.exitCode]) : once(first.child, 'close');
      if (mode === 'crash') first.child.kill('SIGKILL');
      const [code, signal] = await ended;
      if (mode === 'normal') assert.equal(code, 0, first.log()); else assert.equal(signal, 'SIGKILL');
      await sleep(150);
      process.kill(before.hostPid, 0);
      if (!real) await waitFor(() => Number(fs.readFileSync(path.join(options.home, 'ticks'))) > ticks);
      second = client(root, 'resume', real, wrapper);
      const [resumed] = await once(second.child, 'close'); assert.equal(resumed, 0, second.log());
      const after = await inspect(options);
      assert.equal(after.hostPid, before.hostPid);
      assert.equal(after.generation, before.generation);
      if (!real) assert.equal(fs.readFileSync(path.join(options.home, 'launch-count'), 'utf8'), '1');
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'resume-result.json'))).generation, before.generation);
    } finally {
      for (const c of [first, second]) if (c && c.child.exitCode === null && c.child.signalCode === null) c.child.kill('SIGKILL');
      const state = await inspect(options);
      if (['running', 'starting'].includes(state.status)) await shutdown(options);
      await sleep(80);
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
