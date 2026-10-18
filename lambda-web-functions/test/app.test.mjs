// Tests of app/core.mjs: it must never echo a header value, only presence and a hash.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { route, normalisePath, ENV_ID, slowMs, SLOW_MAX_MS } from '../app/core.mjs';

async function call(path, headers = {}, method = 'GET') {
  const u = new URL(path, 'http://x');
  let status = 0; let hdrs = {}; let body = '';
  await route({ kind: 'test', method, path: u.pathname, query: u.searchParams, headers }, {
    start: (s, h) => { status = s; hdrs = h; }, write: (c) => { body += c; }, end: () => {},
  });
  return { status, hdrs, body };
}

test('normalisePath strips only the leading /wf or /fu', () => {
  assert.equal(normalisePath('/wf/ping'), '/ping');
  assert.equal(normalisePath('/fu'), '/');
  assert.equal(normalisePath('/wfx/ping'), '/wfx/ping');
  assert.equal(normalisePath('/a/wf/b'), '/a/wf/b');
});

test('/headers returns presence and sha256, never the value', async () => {
  const r = await call('/wf/headers', { host: 'h.example', authorization: 'Bearer secret-jwt', 'x-app-auth': 'app-secret' });
  const j = JSON.parse(r.body);
  assert.equal(j.authorization.sha256, createHash('sha256').update('Bearer secret-jwt').digest('hex'));
  assert.equal(j['x-app-auth'].present, true);
  assert.equal(j.host, 'h.example');
  assert.ok(!r.body.includes('secret-jwt'));
  assert.ok(!r.body.includes('app-secret'));
  const none = JSON.parse((await call('/headers', {})).body);
  assert.equal(none.authorization.present, false);
});

test('/ping carries the environment id; /cache is cacheable; unknown path 404; POST refused', async () => {
  const p = await call('/ping');
  assert.equal(JSON.parse(p.body).env, ENV_ID);
  assert.equal(p.hdrs['x-lwf-env'], ENV_ID);
  assert.equal((await call('/cache')).hdrs['cache-control'], 'public, max-age=60');
  assert.equal((await call('/nothing')).status, 404);
  assert.equal((await call('/ping', {}, 'POST')).status, 405);
});

test('/slow waits and reports concurrency; /stream writes the requested chunks', async () => {
  const [a, b] = await Promise.all([call('/slow?ms=30'), call('/slow?ms=30')]);
  assert.equal(JSON.parse(a.body).slept, 30);
  assert.ok(Math.max(JSON.parse(a.body).maxInflight, JSON.parse(b.body).maxInflight) >= 2);
  const s = await call('/stream?chunks=3&gap=5');
  assert.equal(s.body.trim().split('\n').length, 3);
});

test('/slow is capped at 3000 ms (a long hold would keep environments busy and billed)', () => {
  assert.equal(SLOW_MAX_MS, 3000);
  assert.equal(slowMs('99999'), 3000);
  assert.equal(slowMs('2000'), 2000);
  assert.equal(slowMs('-5'), 0);
  assert.equal(slowMs(null), 2000);
});
