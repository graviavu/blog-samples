// Tests of worker/worker.mjs with a fake fetch and a fake Cache API (no network).
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../worker/worker.mjs';

const env = {
  WF_HOST: 'wf.example.test', FU_HOST: 'fu.example.test', CF_ORIGIN: 'cdn.example.test', AWS_REGION: 'us-east-1',
  AWS_ACCESS_KEY_ID: 'AKIDEXAMPLE', AWS_SECRET_ACCESS_KEY: 'example-secret-for-tests-only',
};
const ctx = { waitUntil: () => {} };

function withFakes(fn) {
  const calls = [];
  const store = new Map();
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response('{"ok":true}', { status: 200, headers: { 'cache-control': 'public, max-age=60', 'content-type': 'application/json' } });
  };
  globalThis.caches = { default: { match: async (k) => store.get(k.url)?.clone(), put: async (k, v) => { store.set(k.url, v); } } };
  return fn(calls).finally(() => { delete globalThis.fetch; delete globalThis.caches; });
}

test('/wf is signed for service lambda, Authorization from the viewer is not forwarded, x-app-auth is', () => withFakes(async (calls) => {
  const req = new Request('https://w.test/wf/headers?a=1', { headers: { authorization: 'Bearer viewer-token', 'x-app-auth': 'app-token', 'cf-ray': 'x' } });
  const res = await worker.fetch(req, env, ctx);
  assert.equal(res.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://wf.example.test/headers?a=1');
  const h = calls[0].init.headers;
  assert.match(h.authorization, /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/\d{8}\/us-east-1\/lambda\/aws4_request/);
  assert.ok(!h.authorization.includes('viewer-token'));
  assert.equal(h['x-app-auth'], 'app-token');
  assert.equal(h['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD');
  assert.equal(h['cf-ray'], undefined);
  assert.match(res.headers.get('server-timing'), /worker-subrequest;dur=\d+/);
}));

test('/fu goes to the function URL host; /cf is unsigned and goes to CloudFront', () => withFakes(async (calls) => {
  await worker.fetch(new Request('https://w.test/fu/ping'), env, ctx);
  await worker.fetch(new Request('https://w.test/cf/wf/ping', { headers: { authorization: 'Bearer t' } }), env, ctx);
  assert.equal(calls[0].url, 'https://fu.example.test/ping');
  assert.equal(calls[1].url, 'https://cdn.example.test/wf/ping');
  assert.equal(calls[1].init.headers.authorization, undefined);
}));

test('missing key gives a clear 500 and no upstream call', () => withFakes(async (calls) => {
  const res = await worker.fetch(new Request('https://w.test/wf/ping'), { ...env, AWS_SECRET_ACCESS_KEY: '' }, ctx);
  assert.equal(res.status, 500);
  assert.equal(calls.length, 0);
}));

test('cache route: miss then hit, one upstream call', () => withFakes(async (calls) => {
  const puts = [];
  const c = globalThis.caches.default; const put = c.put;
  c.put = async (k, v) => { puts.push(put(k, v)); };
  const r1 = await worker.fetch(new Request('https://w.test/cache/wf/cache'), env, { waitUntil: (p) => p });
  await Promise.all(puts);
  const r2 = await worker.fetch(new Request('https://w.test/cache/wf/cache'), env, ctx);
  assert.equal(r1.headers.get('x-lwf-cache'), 'MISS');
  assert.equal(r2.headers.get('x-lwf-cache'), 'HIT');
  assert.equal(calls.length, 1);
}));

test('edge routes are answered by the Worker, other methods and paths are refused', () => withFakes(async (calls) => {
  const r = await worker.fetch(new Request('https://w.test/edge/ping'), env, ctx);
  assert.equal((await r.json()).kind, 'worker');
  assert.equal((await worker.fetch(new Request('https://w.test/nope'), env, ctx)).status, 404);
  assert.equal((await worker.fetch(new Request('https://w.test/wf/x', { method: 'POST', body: 'x' }), env, ctx)).status, 405);
  assert.equal(calls.length, 0);
}));

test('edge stream sends several chunks', () => withFakes(async () => {
  const r = await worker.fetch(new Request('https://w.test/edge/stream?chunks=3&gap=5'), env, ctx);
  const text = await r.text();
  assert.equal(text.trim().split('\n').length, 3);
}));
