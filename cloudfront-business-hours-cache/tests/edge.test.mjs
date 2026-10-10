// Unit tests for edge/index.mjs. No AWS, no SDK: the S3 read is replaced by a function. Run: node --test tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { makeHandler, parseConfig, cacheControlFor, originForbidsShared, FALLBACK_CACHE_CONTROL } from '../edge/index.mjs';

const CFG = { startMin: 780, endMin: 1080, inTtl: 0, outTtl: 14400 }; // 13:00 to 18:00 UTC
const CFG_TEXT = JSON.stringify(CFG);
const at = (h, m, s = 0) => new Date(Date.UTC(2026, 9, 10, h, m, s));
const OUT = 'public, max-age=0, s-maxage=14400';
const IN = 'public, max-age=0, s-maxage=0';
const ev = (status = '200', headers = {}) => ({ Records: [{ cf: { response: { status, statusDescription: 'x', headers } } }] });
const cc = (r) => r.headers['cache-control'] && r.headers['cache-control'][0].value;

function build({ text = CFG_TEXT, time = at(12, 0), fail = false } = {}) {
  const clock = { t: time, loads: 0, text, fail };
  const handler = makeHandler({
    loadText: async () => { clock.loads += 1; if (clock.fail) throw Object.assign(new Error('AccessDenied for bucket secret-name'), { name: 'AccessDenied' }); return clock.text; },
    now: () => clock.t,
  });
  return { clock, handler };
}

test('inside the window: inTtl (0 = not cached)', async () => {
  const { handler } = build({ time: at(14, 30) });
  assert.equal(cc(await handler(ev())), IN);
});

test('outside the window: outTtl', async () => {
  for (const t of [at(0, 0), at(12, 59), at(18, 1), at(23, 59)]) {
    const { handler } = build({ time: t });
    assert.equal(cc(await handler(ev())), OUT, t.toISOString());
  }
});

test('boundaries: startMin inclusive, endMin exclusive', async () => {
  assert.equal(cacheControlFor(CFG, at(12, 59, 59)), OUT);
  assert.equal(cacheControlFor(CFG, at(13, 0, 0)), IN);   // startMin itself is inside
  assert.equal(cacheControlFor(CFG, at(17, 59, 59)), IN);
  assert.equal(cacheControlFor(CFG, at(18, 0, 0)), OUT);  // endMin itself is outside
});

test('a window ending at 1440 includes 23:59, one starting at 0 includes 00:00', () => {
  assert.equal(cacheControlFor({ ...CFG, startMin: 1200, endMin: 1440 }, at(23, 59)), IN);
  assert.equal(cacheControlFor({ ...CFG, startMin: 0, endMin: 60 }, at(0, 0)), IN);
});

test('a non-zero inTtl is used as given', () => {
  assert.equal(cacheControlFor({ ...CFG, inTtl: 60 }, at(14, 0)), 'public, max-age=0, s-maxage=60');
});

test('error statuses are not rewritten', async () => {
  const { handler, clock } = build({ time: at(12, 0) });
  for (const status of ['400', '404', '500', '503', 500]) {
    const r = await handler(ev(status, { 'cache-control': [{ key: 'Cache-Control', value: 'origin-value' }] }));
    assert.equal(cc(r), 'origin-value', String(status));
  }
  assert.equal(clock.loads, 0, 'errors do not even read the config');
});

test('only 200, 203, 204 and 206 are rewritten', async () => {
  const { handler } = build({ time: at(12, 0) });
  for (const status of ['200', '203', '204', '206', 200]) assert.equal(cc(await handler(ev(status))), OUT, String(status));
});

test('redirects, 304 and other statuses are left untouched', async () => {
  const { handler, clock } = build({ time: at(12, 0) });
  for (const status of ['201', '205', '301', '302', '304']) {
    const r = await handler(ev(status, {}));
    assert.equal(r.headers['cache-control'], undefined, status);
  }
  assert.equal(clock.loads, 0);
});

test('origin private, no-store or no-cache: response left untouched', async () => {
  for (const v of ['private', 'no-store', 'no-cache', 'public, no-cache', 'max-age=0, No-Store', 'private, max-age=60', 'no-cache="set-cookie"']) {
    const { handler } = build({ time: at(12, 0) });
    const r = await handler(ev('200', { 'cache-control': [{ key: 'Cache-Control', value: v }] }));
    assert.equal(cc(r), v, v);
  }
});

test('origin set-cookie: response left untouched, no Cache-Control added', async () => {
  const { handler } = build({ time: at(12, 0) });
  const r = await handler(ev('200', { 'set-cookie': [{ key: 'Set-Cookie', value: 'a=b' }] }));
  assert.equal(r.headers['cache-control'], undefined);
});

test('harmless origin Cache-Control (public, max-age) is replaced; look-alike words do not count', async () => {
  for (const v of ['public, max-age=60', 'max-age=0', 'x-private-ish=1', 'privately=1']) {
    const { handler } = build({ time: at(12, 0) });
    const r = await handler(ev('200', { 'cache-control': [{ key: 'Cache-Control', value: v }] }));
    assert.equal(cc(r), OUT, v);
  }
  assert.equal(originForbidsShared(undefined), false);
});

test('S3 read failure: fallback s-maxage=0, never a long TTL, nothing leaks into the log', async () => {
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  try {
    const { handler } = build({ time: at(12, 0), fail: true });
    assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL);
  } finally { console.log = orig; }
  assert.equal(FALLBACK_CACHE_CONTROL, IN);
  assert.ok(logs.length > 0);
  assert.ok(!logs.join('\n').includes('secret-name'), 'error message text must not be logged');
});

test('bad JSON, wrong shape and bad numbers all give the fallback', async () => {
  const bad = ['not json', '', 'null', '[]', '"x"', '{}',
    JSON.stringify({ ...CFG, startMin: 1080, endMin: 780 }),   // start after end (no overnight window)
    JSON.stringify({ ...CFG, startMin: 780, endMin: 780 }),    // empty window
    JSON.stringify({ ...CFG, startMin: -1 }),
    JSON.stringify({ ...CFG, endMin: 1441 }),
    JSON.stringify({ ...CFG, outTtl: -5 }),
    JSON.stringify({ ...CFG, outTtl: '14400' }),               // string, not a number
    JSON.stringify({ ...CFG, inTtl: 1.5 }),
    JSON.stringify({ startMin: 780, endMin: 1080, inTtl: 0 })];  // outTtl missing
  for (const text of bad) {
    const { handler } = build({ text, time: at(12, 0) });
    assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL, text);
  }
  assert.equal(parseConfig(CFG_TEXT) !== null, true);
});

test('the config is cached for 30 s, then read again', async () => {
  const { handler, clock } = build({ time: at(12, 0, 0) });
  await handler(ev());
  clock.t = at(12, 0, 29); await handler(ev());
  assert.equal(clock.loads, 1);
  clock.text = JSON.stringify({ ...CFG, outTtl: 60 });
  clock.t = at(12, 0, 31); assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=60');
  assert.equal(clock.loads, 2);
});

test('after the cache expires a failing read gives the fallback, not the old long TTL', async () => {
  const { handler, clock } = build({ time: at(12, 0, 0) });
  assert.equal(cc(await handler(ev())), OUT);
  clock.fail = true;
  clock.t = at(12, 0, 10); assert.equal(cc(await handler(ev())), OUT, 'still inside the 30 s memory cache');
  clock.t = at(12, 0, 31); assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL);
});

test('a failure is remembered for a few seconds only, then S3 is tried again', async () => {
  const { handler, clock } = build({ time: at(12, 0, 0), fail: true });
  await handler(ev()); clock.t = at(12, 0, 3); await handler(ev());
  assert.equal(clock.loads, 1);
  clock.fail = false; clock.t = at(12, 0, 6);
  assert.equal(cc(await handler(ev())), OUT);
  assert.equal(clock.loads, 2);
});

test('the same config is evaluated against the clock on every request (window opens without a config reload)', async () => {
  const { handler, clock } = build({ time: at(12, 59, 50) });
  assert.equal(cc(await handler(ev())), OUT);
  clock.t = at(13, 0, 5);
  assert.equal(cc(await handler(ev())), IN);
  assert.equal(clock.loads, 1);
});

test('other response headers are kept', async () => {
  const { handler } = build();
  const r = await handler(ev('200', { 'content-type': [{ key: 'Content-Type', value: 'text/plain' }] }));
  assert.equal(r.headers['content-type'][0].value, 'text/plain');
});
