// Controlled stdlib Host peer: no DSH code, credentials, profiles or model calls.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
const home = process.env.DSH_HOME;
if (!home || !path.basename(home).startsWith('fixture-home')) throw new Error('Fake Host requires a disposable fixture-home');
fs.mkdirSync(home, { recursive: true, mode: 0o700 });
const count = path.join(home, 'launch-count');
fs.writeFileSync(count, String(Number(fs.existsSync(count) && fs.readFileSync(count, 'utf8')) + 1));
let ticks = 0;
const ticker = setInterval(() => fs.writeFileSync(path.join(home, 'ticks'), String(++ticks)), 50);
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/?token=fixture-secret-123')) {
    res.writeHead(303, { Location: '/', 'Set-Cookie': 'dsh-auth-fixture=private; HttpOnly; SameSite=Strict' });
    res.end(); return;
  }
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    try {
      const request = JSON.parse(body);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ type: 'server-response', rpcId: request.rpcId,
        result: { ok: true, value: { items: [{ sessionId: 'fixture-session', pid: process.pid }] } } }));
    } catch { res.writeHead(400); res.end(); }
  });
});
server.listen(0, '127.0.0.1', () => {
  // Deliberately split the launch credential: no client may authenticate a partial token.
  process.stdout.write(`dsh web: http://127.0.0.1:${server.address().port}/?token=fixture-`);
  setTimeout(() => process.stdout.write('secret-123\n'), 50);
});
process.on('SIGTERM', () => {
  clearInterval(ticker);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 100).unref();
});
