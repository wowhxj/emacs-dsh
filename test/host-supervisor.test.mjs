import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { ensure, inspect, shutdown } from '../emacs-dsh-host.mjs';
const helper = fileURLToPath(new URL('../emacs-dsh-host.mjs', import.meta.url));
const fake = fileURLToPath(new URL('./fake-host.mjs', import.meta.url));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 6000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const v = await predicate(); if (v) return v; await sleep(20); }
  throw new Error('Host fixture deadline exceeded');
}
function fixture() {
  const root = fs.mkdtempSync('/tmp/dsh-h-'); fs.chmodSync(root, 0o700);
  return { root, options: { runtime: path.join(root, 'run'), home: path.join(root, 'fixture-home'),
    cwd: root, argv: [process.execPath, fake], startupTimeout: 2000 } };
}
function client(options) {
  const child = spawn(process.execPath, [helper, 'connect', Buffer.from(JSON.stringify(options)).toString('base64')], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = '';
  child.stdout.on('data', bytes => { output += bytes; });
  child.stderr.on('data', bytes => { errors += bytes; });
  child.stdin.on('error', () => {});
  return { child, output: () => output, errors: () => errors,
    async ready() { await waitFor(() => { if (child.exitCode !== null) throw new Error(errors); return output.includes('secret-123\n'); }); },
    async detach(signal) { const end = once(child, 'close'); if (signal) child.kill(signal); else child.stdin.end(); await end; },
  };
}
async function cleanup(f, clients = []) {
  for (const c of clients) if (c.child.exitCode === null && c.child.signalCode === null) await c.detach();
  const state = await inspect(f.options);
  if (['running', 'starting'].includes(state.status)) await shutdown(f.options);
  await sleep(80);
  fs.rmSync(f.root, { recursive: true, force: true });
}

test('read-only inspection does not start a Host or create registry files', async () => {
  const f = fixture();
  try {
    assert.equal((await inspect(f.options)).status, 'absent');
    assert.equal(fs.existsSync(f.options.runtime), false);
    assert.equal(fs.existsSync(f.options.home), false);
  } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
});
for (const signal of [null, 'SIGKILL']) {
  test(`Host keeps work after helper ${signal || 'EOF'} and reuses same generation`, { timeout: 12000 }, async () => {
    const f = fixture(), clients = [];
    try {
      const a = client(f.options); clients.push(a); await a.ready();
      const before = await inspect(f.options);
      assert.equal(before.status, 'running'); assert.match(before.launch, /fixture-secret-123$/);
      await waitFor(() => fs.existsSync(path.join(f.options.home, 'ticks')));
      const ticks = Number(fs.readFileSync(path.join(f.options.home, 'ticks')));
      await a.detach(signal); await sleep(120);
      assert.ok(Number(fs.readFileSync(path.join(f.options.home, 'ticks'))) > ticks);
      const b = client(f.options); clients.push(b); await b.ready();
      const after = await inspect(f.options);
      assert.equal(after.hostPid, before.hostPid); assert.equal(after.generation, before.generation);
      assert.equal(fs.readFileSync(path.join(f.options.home, 'launch-count'), 'utf8'), '1');
      const instance = await ensure(f.options);
      assert.equal(fs.readFileSync(path.join(instance.directory, 'host.log'), 'utf8').includes('fixture-secret-123'), false);
      assert.equal((await shutdown(f.options)).status, 'exited');
      await waitFor(() => b.child.exitCode !== null);
    } finally { await cleanup(f, clients); }
  });
}

test('multiple clients share one Host without acquiring exclusive agent ownership', { timeout: 12000 }, async () => {
  const f = fixture(), clients = [];
  try {
    const a = client(f.options), b = client(f.options); clients.push(a, b);
    await Promise.all([a.ready(), b.ready()]);
    assert.equal(fs.readFileSync(path.join(f.options.home, 'launch-count'), 'utf8'), '1');
    await a.detach();
    assert.equal((await inspect(f.options)).status, 'running');
    assert.equal(b.child.exitCode, null);
  } finally { await cleanup(f, clients); }
});

test('different DSH homes get different Host identities', { timeout: 12000 }, async () => {
  const a = fixture(), b = fixture();
  try {
    const one = await ensure(a.options), two = await ensure(b.options);
    await waitFor(async () => (await inspect(a.options)).status === 'running');
    await waitFor(async () => (await inspect(b.options)).status === 'running');
    assert.notEqual(one.supervisorPid, two.supervisorPid);
    await shutdown(a.options);
    assert.equal((await inspect(b.options)).status, 'running');
  } finally { await cleanup(a); await cleanup(b); }
});

test('changed launch settings cannot create a second Host for the same profile', { timeout: 12000 }, async () => {
  const f = fixture();
  try {
    await ensure(f.options);
    await waitFor(async () => (await inspect(f.options)).status === 'running');
    const changed = { ...f.options, argv: [...f.options.argv, '--changed-setting'] };
    await assert.rejects(ensure(changed), /different launch settings/);
    assert.equal((await inspect(changed)).status, 'unknown');
    assert.equal(fs.readFileSync(path.join(f.options.home, 'launch-count'), 'utf8'), '1');
    assert.equal((await inspect(f.options)).status, 'running');
  } finally { await cleanup(f); }
});

test('missing executable fails without a leftover listening supervisor', { timeout: 12000 }, async () => {
  const f = fixture(); f.options.argv = ['/missing-dsh-host-fixture'];
  try {
    try { await ensure(f.options); } catch {}
    await waitFor(async () => ['failed', 'exited'].includes((await inspect(f.options)).status));
    assert.equal((await inspect(f.options)).status, 'failed');
  } finally { await cleanup(f); }
});
