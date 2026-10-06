import test from 'node:test';
import assert from 'node:assert/strict';
import { loadEdge, edgeEvent, T } from './helpers.mjs';

const run = async (opts, status = 200, headers = {}) => {
  const res = await loadEdge(opts)(edgeEvent(status, headers));
  return res;
};
const cc = (res) => res.headers['cache-control'];

test('in the window: s-maxage = IN_TTL, max-age=0 for browsers', async () => {
  const res = await run({ start: 810, end: 1200, inTtl: 15, outTtl: 45, now: T('2026-10-05T14:00:00Z') });
  assert.deepEqual(cc(res), [{ key: 'Cache-Control', value: 'public, max-age=0, s-maxage=15' }]);
});

test('outside the window: s-maxage = OUT_TTL (before and after)', async () => {
  for (const iso of ['2026-10-05T08:00:00Z', '2026-10-05T21:00:00Z']) {
    const res = await run({ start: 810, end: 1200, inTtl: 15, outTtl: 45, now: T(iso) });
    assert.equal(cc(res)[0].value, 'public, max-age=0, s-maxage=45', iso);
  }
});

test('window edges: start inclusive, end exclusive', async () => {
  const o = { start: 810, end: 1200, inTtl: 15, outTtl: 45 };
  assert.match(cc(await run({ ...o, now: T('2026-10-05T13:30:00Z') }))[0].value, /s-maxage=15$/);
  assert.match(cc(await run({ ...o, now: T('2026-10-05T13:29:59Z') }))[0].value, /s-maxage=45$/);
  assert.match(cc(await run({ ...o, now: T('2026-10-05T19:59:59Z') }))[0].value, /s-maxage=15$/);
  assert.match(cc(await run({ ...o, now: T('2026-10-05T20:00:00Z') }))[0].value, /s-maxage=45$/);
});

test('the default constants (0 to 1440) put the whole UTC day in the window', async () => {
  for (const iso of ['2026-10-05T00:00:00Z', '2026-10-05T23:59:59Z']) {
    assert.match(cc(await run({ now: T(iso) }))[0].value, /s-maxage=15$/);
  }
});

test('replaces whatever Cache-Control the origin sent, whatever its case, and keeps other headers', async () => {
  const res = await run({ now: T('2026-10-05T14:00:00Z') }, 200, {
    'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
    'content-type': [{ key: 'Content-Type', value: 'application/json' }],
  });
  assert.equal(cc(res).length, 1);
  assert.match(cc(res)[0].value, /s-maxage=15$/);
  assert.equal(res.headers['content-type'][0].value, 'application/json');
});

test('errors (400 and above) are not rewritten by default and keep the origin header', async () => {
  for (const status of [400, 403, 404, 500, 503]) {
    const res = await run({ now: T('2026-10-05T14:00:00Z') }, status, { 'cache-control': [{ key: 'Cache-Control', value: 'public, s-maxage=60' }] });
    assert.equal(cc(res)[0].value, 'public, s-maxage=60', String(status));
    const bare = await run({ now: T('2026-10-05T14:00:00Z') }, status);
    assert.equal(cc(bare), undefined, `${status} without a header stays without`);
  }
});

test('REWRITE_ERRORS=true rewrites errors too (to test whether they become cacheable)', async () => {
  const res = await run({ now: T('2026-10-05T14:00:00Z'), rewriteErrors: true }, 403);
  assert.match(cc(res)[0].value, /s-maxage=15$/);
});

test('3xx and 304 are rewritten (status below 400)', async () => {
  assert.match(cc(await run({ now: T('2026-10-05T14:00:00Z') }, 304))[0].value, /s-maxage=15$/);
});
