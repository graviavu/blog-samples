import test from 'node:test';
import assert from 'node:assert/strict';
import { loadOrigin, urlEvent } from './helpers.mjs';

const origin = loadOrigin();
const call = async (path, opts) => {
  const r = await origin(urlEvent(path, opts));
  return { ...r, json: r.body ? JSON.parse(r.body) : null };
};

const CC = {
  none: undefined, nostore: 'no-store', private: 'private', nocache: 'no-cache', 'public-nomax': 'public',
  'maxage-0': 'public, max-age=0', 'maxage-5': 'public, max-age=5', 'maxage-30': 'public, max-age=30', 'maxage-3600': 'public, max-age=3600',
  'smaxage-only': 'public, s-maxage=5', 'both-5': 'public, max-age=0, s-maxage=5', 'both-14400': 'public, max-age=0, s-maxage=14400',
  'maxage-expires': 'public, max-age=5', etag: 'public, max-age=5', slow: 'no-store',
};

for (const [route, cc] of Object.entries(CC)) {
  test(`route ${route}: Cache-Control ${cc === undefined ? '(none)' : cc}`, async () => {
    const r = await call(`/p-b/run1/${route}`);
    assert.equal(r.statusCode, 200);
    assert.equal(r.headers['cache-control'], cc);
    assert.equal(r.json.route, route);
    assert.equal(r.json.sentCacheControl, cc || null);
  });
}

test('Expires routes', async () => {
  const past = await call('/a/expires-past');
  assert.equal(past.headers.expires, 'Thu, 01 Jan 1970 00:00:00 GMT');
  assert.equal(past.headers['cache-control'], undefined, 'Expires only: no Cache-Control');
  const both = await call('/a/maxage-expires');
  assert.equal(both.headers['cache-control'], 'public, max-age=5');
  assert.match(both.headers.expires, /2100/);
});

for (const code of [400, 403, 404, 500, 503]) {
  test(`error-${code} without and with Cache-Control`, async () => {
    const a = await call(`/a/error-${code}`);
    assert.equal(a.statusCode, code);
    assert.equal(a.headers['cache-control'], undefined);
    const b = await call(`/a/error-${code}-cc`);
    assert.equal(b.statusCode, code);
    assert.equal(b.headers['cache-control'], 'public, s-maxage=60');
  });
}

test('every response carries a unique id and a timestamp', async () => {
  const ids = new Set();
  for (let i = 0; i < 50; i++) {
    const r = await call('/a/none');
    ids.add(r.json.id);
    assert.match(r.json.id, /^[0-9a-f-]{36}$/);
    assert.ok(Math.abs(Date.parse(r.json.ts) - r.json.epoch) < 5);
  }
  assert.equal(ids.size, 50);
});

test('the route is the last path segment; the rest of the path is ignored and never reflected', async () => {
  const r = await call('/p-b/run-<script>alert(1)</script>/maxage-5');
  assert.equal(r.statusCode, 200);
  assert.equal(r.json.route, 'maxage-5');
  assert.ok(!r.body.includes('script'));
  assert.ok(!JSON.stringify(r.headers).includes('script'));
});

test('unknown routes: 404, no-store, nothing from the request in the output', async () => {
  for (const path of ['/', '', '/nope', '/a/<img src=x>', '/a/__proto__', '/a/constructor', '/a/toString', '/a/NONE', '/a/none/', `/a/${'x'.repeat(500)}`]) {
    const r = await call(path);
    assert.equal(r.statusCode, 404, path);
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.deepEqual(r.json, { error: 'unknown route' });
  }
  const noPath = await origin({ headers: {} });
  assert.equal(noPath.statusCode, 404);
});

test('slot in the query string: echoed only if it matches the allow-list', async () => {
  const ok = ['w123456789', 'f9', 'pre-2026-10-05-r1', 'post-2026-10-05-r999999', 'closed-2026-10-05'];
  for (const s of ok) {
    const r = await call('/a/none', { query: { slot: s } });
    assert.equal(r.json.sawSlot, true);
    assert.equal(r.json.slot, s);
    assert.equal(r.json.slotInvalid, false);
  }
  const bad = ['evil', 'w1,w2', 'w', 'wabc', 'w1234567890123', 'pre-2026-10-05', 'pre-2026-10-05-r1\nSet-Cookie: x=1', '<b>', '', 'W1', ' w1'];
  for (const s of bad) {
    const r = await call('/a/none', { query: { slot: s } });
    assert.equal(r.json.sawSlot, true, JSON.stringify(s));
    assert.equal(r.json.slot, null, JSON.stringify(s));
    assert.equal(r.json.slotInvalid, true);
    assert.ok(!r.body.includes('evil') && !r.body.includes('<b>'));
  }
  const none = await call('/a/none');
  assert.equal(none.json.sawSlot, false);
  assert.equal(none.json.slot, null);
  const other = await call('/a/none', { query: { other: 'evil' } });
  assert.equal(other.json.sawSlot, false);
  assert.ok(!other.body.includes('evil'));
});

test('slot in the x-cache-slot header: same rules', async () => {
  const ok = await call('/a/none', { headers: { 'x-cache-slot': 'post-2026-10-05-r3' } });
  assert.equal(ok.json.sawSlotHeader, true);
  assert.equal(ok.json.slotHeader, 'post-2026-10-05-r3');
  const bad = await call('/a/none', { headers: { 'x-cache-slot': 'evil' } });
  assert.equal(bad.json.slotHeader, null);
  assert.equal(bad.json.slotHeaderInvalid, true);
  assert.ok(!bad.body.includes('evil'));
  assert.equal((await call('/a/none')).json.sawSlotHeader, false);
});

test('etag route: 304 for a matching If-None-Match, 200 otherwise, never reflects the header', async () => {
  const first = await call('/a/etag');
  assert.equal(first.headers.etag, '"tw-fixed-etag"');
  const cond = await origin(urlEvent('/a/etag', { headers: { 'if-none-match': '"tw-fixed-etag"' } }));
  assert.equal(cond.statusCode, 304);
  assert.equal(cond.body, undefined);
  const miss = await call('/a/etag', { headers: { 'if-none-match': '"other"' } });
  assert.equal(miss.statusCode, 200);
  assert.ok(!JSON.stringify(miss).includes('"other"'));
});

test('slow route waits about a second (for the request collapsing test)', async () => {
  const t0 = Date.now();
  await call('/a/slow');
  assert.ok(Date.now() - t0 >= 950);
});

test('no request input reaches any response header', async () => {
  const r = await call('/a/none', { query: { slot: 'evil', x: 'evil' }, headers: { 'x-cache-slot': 'evil', host: 'evil', 'user-agent': 'evil' } });
  assert.ok(!JSON.stringify(r.headers).includes('evil'));
  assert.ok(!r.body.includes('evil'));
});
