// Opt-in installed-CLI smoke. All profile writes are under a disposable DSH_HOME.
// No plugins/dependencies are installed; no sessions or model prompts are created.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { ensure, inspect, shutdown } from '../emacs-dsh-host.mjs';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 35000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await predicate(); if (value) return value; await sleep(50); }
  throw new Error('Isolated real DSH Host deadline exceeded');
}
test('real dsh web is independently owned, authenticated and discovered without model work', {
  skip: process.env.DSH_HOST_REAL !== '1', timeout: 55000,
}, async () => {
  const root = fs.mkdtempSync('/tmp/dsh-real-'); fs.chmodSync(root, 0o700);
  const previousTelemetry = process.env.DSH_TELEMETRY_DISABLED;
  process.env.DSH_TELEMETRY_DISABLED = '1';
  const options = { runtime: path.join(root, 'run'), home: path.join(root, 'home'), cwd: root,
    argv: [process.env.DSH_EXECUTABLE || 'dsh', 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'],
    startupTimeout: 30000 };
  let instance;
  try {
    instance = await ensure(options);
    const state = await waitFor(async () => {
      const info = await inspect(options);
      if (info.status === 'failed' || info.status === 'exited') {
        const log = path.join(instance.directory, 'host.log');
        throw new Error('Isolated DSH failed: ' + (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').slice(-3000) : 'no diagnostic log'));
      }
      return info.status === 'running' && info;
    });
    const login = await fetch(state.launch, { redirect: 'manual' });
    assert.equal(login.status, 303);
    const cookie = login.headers.get('set-cookie')?.split(';')[0];
    assert.match(cookie, /^dsh-auth-/);
    const rpcId = 'real-host-readonly-smoke';
    const reply = await fetch(state.base + 'api/session/list', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: cookie },
      body: JSON.stringify({ type: 'client-request', rpcId, method: 'session/list', payload: { args: { _request: {} } } }),
    });
    assert.equal(reply.status, 200);
    const data = await reply.json();
    assert.equal(data.rpcId, rpcId); assert.equal(data.result.ok, true);
    assert.ok(Array.isArray(data.result.value.items));
    const later = await inspect(options);
    assert.equal(later.hostPid, state.hostPid); assert.equal(later.generation, state.generation);
    assert.equal((await shutdown(options)).status, 'exited');
  } finally {
    const state = await inspect(options);
    if (['running', 'starting'].includes(state.status)) await shutdown(options);
    await sleep(100);
    if (previousTelemetry === undefined) delete process.env.DSH_TELEMETRY_DISABLED;
    else process.env.DSH_TELEMETRY_DISABLED = previousTelemetry;
    fs.rmSync(root, { recursive: true, force: true });
  }
});
