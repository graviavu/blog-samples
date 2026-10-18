// probe.mjs against a local HTTPS server with a self-signed certificate generated at test time (openssl).
import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const probe = join(here, '..', 'tools', 'probe.mjs');
const dir = mkdtempSync(join(tmpdir(), 'lwf-probe-'));
let server; let port; let sawAuth = []; let sawUrl = []; let live = 0;

test.before(async () => {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'), '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
  server = https.createServer({ key: readFileSync(join(dir, 'k.pem')), cert: readFileSync(join(dir, 'c.pem')) }, (req, res) => {
    sawAuth.push(req.headers.authorization || ''); sawUrl.push(req.url);
    if (req.url.startsWith('/stream')) {
      res.writeHead(200, { 'x-lwf-env': 'e1' });
      let i = 0; const t = setInterval(() => { res.write(`c${i}\n`); if (++i === 3) { clearInterval(t); res.end(); } }, 40);
    } else if (req.url.startsWith('/slow')) {
      live++;
      setTimeout(() => { res.writeHead(200, { 'x-lwf-env': 'e' + (Math.random() < 0.5 ? 1 : 2) }); res.end(JSON.stringify({ inflight: live })); live--; }, 50);
    } else { res.writeHead(200, { 'x-cache': 'Hit from cloudfront', 'x-secret-header': 'nope' }); res.end('{"ok":1}'); }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  port = server.address().port;
});
test.after(() => { server.close(); rmSync(dir, { recursive: true, force: true }); });

// async: the test server lives in this process, so a blocking spawnSync would deadlock
function run(args, input) {
  return new Promise((resolve) => {
    const c = spawn(process.execPath, [probe, ...args], { env: { ...process.env, NODE_TLS_REJECT_UNAUTHORIZED: '0' } });
    let out = ''; let err = '';
    c.stdout.on('data', (d) => { out += d; }); c.stderr.on('data', (d) => { err += d; });
    c.on('close', (code) => resolve({ code, out: out.trim() ? JSON.parse(out) : null, err }));
    c.stdin.end(input || '');
  });
}
const U = (p) => `https://localhost:${port}${p}`;

test('get returns status, whitelisted headers and body only', async () => {
  const r = await run(['get', U('/x'), '--header', 'Authorization: Bearer abc']);
  assert.equal(r.out.status, 200);
  assert.equal(r.out.headers['x-cache'], 'Hit from cloudfront');
  assert.equal(r.out.headers['x-secret-header'], undefined);
  assert.ok(!JSON.stringify(r.out).includes('abc'));
});

test('--sign reads the key from stdin and sends a SigV4 Authorization header; no key means error', async () => {
  sawAuth = [];
  const r = await run(['get', U('/x'), '--sign'], JSON.stringify({ id: 'AKIDEXAMPLE', secret: 'example' }));
  assert.equal(r.out.status, 200);
  assert.match(sawAuth[0], /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/\d{8}\/us-east-1\/lambda\/aws4_request/);
  assert.ok(!JSON.stringify(r.out).includes('example'));
  const bad = await run(['get', U('/x'), '--sign'], '');
  assert.equal(bad.code, 2);
});

test('latency, parallel and stream summaries', async () => {
  const l = await run(['latency', U('/x'), '--n', '5', '--warm', '1']);
  assert.equal(l.out.ok, 5); assert.ok(l.out.p50 >= 0);
  const p = await run(['parallel', U('/slow'), '--n', '10']);
  assert.equal(p.out.status['200'], 10); assert.ok(p.out.distinctEnvironments >= 1 && p.out.distinctEnvironments <= 2);
  assert.ok(p.out.maxInflight >= 2, `maxInflight ${p.out.maxInflight}`); // the parallel requests overlapped in the server
  const s = await run(['stream', U('/stream')]);
  assert.equal(s.out.lines, 3); assert.ok(s.out.firstByteMs < s.out.totalMs);
});

test('--sign sends the query exactly as signed (+ as %2B)', async () => {
  sawUrl = [];
  const r = await run(['get', U('/x?a=b+c'), '--sign'], JSON.stringify({ id: 'AKIDEXAMPLE', secret: 'example' }));
  assert.equal(r.out.status, 200);
  assert.equal(sawUrl[0], '/x?a=b%2Bc');
});

test('refuses a non-https URL', async () => {
  assert.equal((await run(['get', 'http://example.test/'])).code, 2);
});
