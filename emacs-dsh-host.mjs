#!/usr/bin/env node
// DSH managed Host ownership. Local clients do not own or pipe the Host's lifetime.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
const VERSION = 1;
const LOG_LIMIT = 1024 * 1024;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
const json = value => JSON.stringify(value) + '\n';
function privateDirectory(dir, create = false) {
  if (create) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) ||
      (process.getuid && stat.uid !== process.getuid())) throw new Error(`Unsafe Host runtime directory: ${dir}`);
}
function read(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 65536 || (stat.mode & 0o077) ||
        (process.getuid && stat.uid !== process.getuid())) throw new Error('Unsafe Host runtime record');
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function save(file, value) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(5).toString('hex')}`;
  fs.writeFileSync(tmp, json(value), { mode: 0o600, flag: 'wx' }); fs.renameSync(tmp, file);
}
function frame(stream, receive, fail) {
  let buffer = '';
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > 65536) { buffer = ''; fail(new Error('Host IPC frame too large')); return; }
    let index;
    while ((index = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
      try { if (line) receive(JSON.parse(line)); } catch (error) { fail(error); }
    }
  });
}
function send(socket, value) {
  if (socket.destroyed) return;
  if (socket.writableLength > 65536) { socket.destroy(); return; }
  socket.write(json(value));
}
function identityPath(input) {
  let current = path.resolve(input);
  const suffix = [];
  while (!fs.existsSync(current)) {
    suffix.unshift(path.basename(current));
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return path.join(fs.realpathSync(current), ...suffix);
}
function normalized(raw, create = false) {
  if (process.platform === 'win32') throw new Error('Persistent managed Host currently requires POSIX');
  if (!Array.isArray(raw.argv) || !raw.argv.length || raw.argv.some(s => typeof s !== 'string' || s.includes('\0'))) throw new Error('Invalid managed Host argv');
  const runtime = path.resolve(raw.runtime || path.join(os.homedir(), '.cache', 'emacs-dsh', 'hosts'));
  if (create || fs.existsSync(runtime)) privateDirectory(runtime, create);
  const home = identityPath(raw.home || process.env.DSH_HOME || path.join(os.homedir(), '.dsh'));
  const args = raw.argv.slice(1);
  const profileIndex = args.indexOf('--profile');
  const profile = profileIndex >= 0 ? args[profileIndex + 1]
    : args.find(arg => arg.startsWith('--profile='))?.slice(10)
      || (args[0] && !args[0].startsWith('-') ? args[0] : 'web');
  // One runtime per actual home/profile, even when arguments or executable change.
  const key = crypto.createHash('sha256').update(JSON.stringify({ home, profile })).digest('hex').slice(0, 32);
  const fingerprint = crypto.createHash('sha256').update(JSON.stringify(raw.argv)).digest('hex');
  const directory = path.join(runtime, key);
  const socket = path.join(directory, 'host.sock');
  if (Buffer.byteLength(socket) > 100) throw new Error('Host runtime socket path too long; configure a shorter path');
  return { ...raw, runtime, home, key, fingerprint, directory, socket,
    info: path.join(directory, 'state.json'), configFile: path.join(directory, 'launch.json'),
    cwd: fs.realpathSync(raw.cwd || os.homedir()) };
}
async function connect(info, op) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(info.socket);
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('Existing Host supervisor is unresponsive')); }, op === 'shutdown' ? 12000 : 1800);
    let settled = false;
    const finish = (value, error) => {
      if (settled) return; settled = true; clearTimeout(timer); socket.end();
      if (error) reject(error); else resolve(value);
    };
    socket.on('connect', () => send(socket, { version: VERSION, token: info.token, op }));
    frame(socket, reply => {
      if (reply.error) finish(null, new Error(reply.error));
      else if (reply.kind === 'info') finish(reply);
    }, error => finish(null, error));
    socket.on('error', error => finish(null, error));
    socket.on('close', () => { if (!settled) finish(null, new Error('Host supervisor disconnected before reply')); });
  });
}
export async function inspect(raw) {
  const p = normalized(raw);
  if (!fs.existsSync(p.directory)) return { status: 'absent', version: VERSION };
  privateDirectory(p.directory);
  const state = read(p.info);
  if (!state) return { status: 'unknown', version: VERSION, error: 'Host launch has no published identity yet' };
  if (['exited', 'failed'].includes(state.status)) return { ...state, kind: 'info', token: undefined };
  if (state.fingerprint !== p.fingerprint) return { status: 'unknown', error: 'Existing Host has different launch settings; no replacement was started' };
  try { return await connect({ ...p, ...state }, 'inspect'); }
  catch (error) { return { status: 'unknown', version: VERSION, generation: state.generation, error: error.message }; }
}
export async function ensure(raw) {
  const p = normalized(raw, true);
  let owner = false;
  try { fs.mkdirSync(p.directory, { mode: 0o700 }); owner = true; }
  catch (error) { if (error.code !== 'EEXIST') throw error; privateDirectory(p.directory); }
  if (!owner) {
    const previous = read(p.info);
    if (previous && alive(previous.supervisorPid) && previous.fingerprint !== p.fingerprint) {
      throw new Error('Existing Host has different launch settings; explicitly shut it down before changing them');
    }
    if (previous && !alive(previous.supervisorPid) && alive(previous.hostPid)) {
      throw new Error('Supervisor lost but Host may still run; refusing duplicate Host');
    }
    if (previous && !alive(previous.supervisorPid) && !alive(previous.hostPid)) {
      try { fs.mkdirSync(path.join(p.directory, 'launch-lock'), { mode: 0o700 }); owner = true; }
      catch { throw new Error('Managed Host launch already in progress'); }
      save(path.join(p.directory, 'previous.json'), { ...previous, token: undefined, launch: undefined });
    }
  }
  let generation;
  if (owner) {
    generation = crypto.randomUUID();
    save(p.configFile, { ...p, token: crypto.randomBytes(32).toString('hex'), generation });
    const daemonLog = path.join(p.directory, 'supervisor.log');
    if (fs.existsSync(daemonLog) && fs.statSync(daemonLog).size > LOG_LIMIT) fs.renameSync(daemonLog, daemonLog + '.1');
    const log = fs.openSync(daemonLog, 'a', 0o600);
    try {
      const child = spawn(process.execPath, [SELF, 'daemon', p.configFile], {
        cwd: p.cwd, stdio: ['ignore', log, log], detached: true,
      });
      child.on('error', () => {}); child.unref();
    } finally { fs.closeSync(log); }
  }
  const deadline = Date.now() + (p.startupTimeout || 35000) + 2000;
  while (Date.now() < deadline) {
    const state = read(p.info);
    if (state && (!owner || state.generation === generation)) {
      if (['failed', 'exited'].includes(state.status)) throw new Error('Managed Host startup failed; inspect private diagnostics');
      if (fs.existsSync(p.socket) && alive(state.supervisorPid)) {
        return { ...p, ...state };
      }
    }
    await sleep(30);
  }
  throw new Error('Managed Host startup deadline exceeded; no duplicate launch');
}

async function daemon(file) {
  process.umask(0o077);
  const config = read(file);
  if (!config) throw new Error('Missing private Host launch config');
  fs.unlinkSync(file);
  const state = { version: VERSION, token: config.token, generation: config.generation,
    status: 'starting', supervisorPid: process.pid, hostPid: null,
    home: config.home, fingerprint: config.fingerprint, socket: config.socket, started: new Date().toISOString() };
  const clients = new Set();
  const waitingShutdown = new Set();
  let host;
  let startupTimer;
  const persist = () => save(config.info, state);
  const publicInfo = () => ({ ...state, kind: 'info', token: undefined });
  const publish = () => { for (const socket of clients) send(socket, publicInfo()); };
  const stop = () => {
    if (host && host.exitCode === null && host.signalCode === null) {
      state.status = 'stopping'; persist();
      // Only the live ChildProcess owned by this supervisor, never an arbitrary stored PID.
      try { process.kill(-host.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const server = net.createServer(socket => {
    const timer = setTimeout(() => socket.destroy(), 3000);
    socket.on('error', () => {});
    frame(socket, request => {
      clearTimeout(timer);
      if (request.version !== VERSION || request.token !== config.token) { socket.destroy(); return; }
      if (request.op === 'inspect') { send(socket, publicInfo()); socket.end(); }
      else if (request.op === 'attach') {
        clients.add(socket);
        if (state.status !== 'starting') send(socket, publicInfo());
      } else if (request.op === 'shutdown') {
        waitingShutdown.add(socket); stop();
        const timeout = setTimeout(() => {
          if (!waitingShutdown.delete(socket)) return;
          send(socket, { error: 'Host remains stopping; no automatic force kill' }); socket.end();
        }, 10000);
        socket.once('close', () => clearTimeout(timeout));
      } else { send(socket, { error: 'Unsupported supervisor operation' }); socket.end(); }
    }, () => socket.destroy());
    socket.once('close', () => { clearTimeout(timer); clients.delete(socket); waitingShutdown.delete(socket); });
  });
  persist();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(config.socket, resolve); });
  try { fs.rmdirSync(path.join(config.directory, 'launch-lock')); } catch {}
  let tail = '';
  function output(bytes) {
    tail = (tail + bytes.toString('utf8')).slice(-8192);
    if (state.status === 'starting') {
      const launch = tail.match(/dsh web:\s*(http:\/\/127\.0\.0\.1:(\d+)\/\?token=[A-Za-z0-9_-]+)(?=[\r\n\s])/);
      if (launch && Number(launch[2]) > 0 && Number(launch[2]) <= 65535) {
        state.base = `http://127.0.0.1:${launch[2]}/`; state.launch = launch[1];
        state.status = 'running'; clearTimeout(startupTimer); persist(); publish();
      }
    }
    // Launch credentials stay only in private state, never in diagnostic logs.
    const sanitized = tail.replace(/(\?token=)[A-Za-z0-9_-]+/g, '$1[redacted]');
    const logFile = path.join(config.directory, 'host.log');
    try {
      const encoded = Buffer.from(sanitized.slice(-8192));
      if (fs.existsSync(logFile) && fs.statSync(logFile).size + encoded.length > LOG_LIMIT) fs.renameSync(logFile, logFile + '.1');
      fs.appendFileSync(logFile, encoded, { mode: 0o600 });
    } catch { /* Diagnostic disk failure must not kill running user work. */ }
  }
  host = spawn(config.argv[0], config.argv.slice(1), {
    cwd: config.cwd, env: { ...process.env, DSH_HOME: config.home },
    detached: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  state.hostPid = host.pid || null; persist();
  host.stdin.on('error', () => {});
  host.stdout.on('data', output); host.stderr.on('data', output);
  host.on('error', () => { state.status = 'failed'; persist(); publish(); });
  host.on('close', (code, signal) => {
    clearTimeout(startupTimer);
    state.status = code === 0 || state.status === 'stopping' ? 'exited' : 'failed';
    state.exitCode = code; state.signal = signal; state.ended = new Date().toISOString();
    delete state.launch; persist(); publish();
    for (const socket of waitingShutdown) { send(socket, publicInfo()); socket.end(); }
    for (const socket of clients) socket.end();
    server.close(); try { fs.unlinkSync(config.socket); } catch {}
    setTimeout(() => process.exit(0), 30);
  });
  startupTimer = setTimeout(() => {
    if (state.status === 'starting') { state.error = 'Host did not publish a local launch URL'; stop(); publish(); }
  }, config.startupTimeout || 35000);
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, stop);
}

async function proxy(raw) {
  const instance = await ensure(raw);
  const socket = net.createConnection(instance.socket);
  socket.on('connect', () => send(socket, { version: VERSION, token: instance.token, op: 'attach' }));
  frame(socket, info => {
    if (info.status === 'running') {
      // This is a private pipe to the Emacs filter, never a public log.
      process.stdout.write(`emacs-dsh generation: ${info.generation}\ndsh web: ${info.launch}\n`);
    } else if (['stopping', 'failed', 'exited'].includes(info.status)) {
      process.stderr.write('Managed Host unavailable; inspect private diagnostics\n');
      process.exitCode = 1; socket.end();
    }
  }, () => { process.exitCode = 1; socket.destroy(); });
  socket.on('error', () => { process.stderr.write('Managed Host IPC unavailable; no duplicate launch\n'); process.exitCode = 1; });
  socket.on('close', () => process.stdin.destroy());
  process.stdin.resume();
  process.stdin.on('end', () => socket.end());
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { socket.destroy(); process.stdin.destroy(); });
}
export async function shutdown(raw) {
  const p = normalized(raw);
  const state = read(p.info);
  if (!state || ['failed', 'exited'].includes(state.status)) return { kind: 'info', status: 'absent' };
  return connect({ ...p, ...state }, 'shutdown');
}

if (process.argv[1] && path.resolve(process.argv[1]) === SELF) {
  const [mode, value] = process.argv.slice(2);
  const config = mode === 'daemon' ? value : JSON.parse(Buffer.from(value || '', 'base64').toString('utf8'));
  const task = mode === 'daemon' ? daemon(config) : mode === 'connect' ? proxy(config)
    : mode === 'inspect' ? inspect(config).then(info => process.stdout.write(json(info)))
    : mode === 'shutdown' ? shutdown(config).then(info => process.stdout.write(json(info)))
    : Promise.reject(new Error('Unknown Host supervisor mode'));
  task.catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
