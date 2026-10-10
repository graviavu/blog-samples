// Unit tests for edge/index.mjs. No AWS, no SDK: the S3 read is replaced by a function. Run: node --test tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { handler as realHandler, makeHandler, parseConfig, selectWindow, cacheControlFor, ttlSecondsFor, originForbidsShared, FALLBACK_CACHE_CONTROL } from '../edge/index.mjs';

const CFG = { startMin: 780, endMin: 1080, inTtl: 0, outTtl: 14400 }; // 13:00 to 18:00 UTC
const CFG_TEXT = JSON.stringify({ default: CFG });   // one default window for every path
const at = (h, m, s = 0) => new Date(Date.UTC(2026, 9, 10, h, m, s));
const OUT = 'public, max-age=0, s-maxage=14400';
const IN = 'public, max-age=0, s-maxage=0';
const ev = (status = '200', headers = {}, uri = '/page') => ({ Records: [{ cf: { request: { uri }, response: { status, statusDescription: 'x', headers } } }] });
const cc = (r) => r.headers['cache-control'] && r.headers['cache-control'][0].value;

function build({ text = CFG_TEXT, time = at(0, 30), fail = false } = {}) {
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

test('outside the window: outTtl, capped by the time until the next opening', async () => {
  const cases = [[at(0, 0), 14400], [at(0, 30), 14400], [at(8, 59), 14400], [at(9, 0), 14400], [at(10, 0), 10800],
    [at(12, 0), 3600], [at(12, 59), 60], [at(18, 0), 14400], [at(18, 1), 14400], [at(23, 59), 14400]];
  for (const [t, ttl] of cases) {
    const { handler } = build({ time: t });
    assert.equal(cc(await handler(ev())), `public, max-age=0, s-maxage=${ttl}`, t.toISOString());
  }
});

test('boundaries: startMin inclusive, endMin exclusive, seconds precision', async () => {
  assert.equal(cacheControlFor(CFG, at(12, 59, 58)), 'public, max-age=0, s-maxage=2');
  assert.equal(cacheControlFor(CFG, at(12, 59, 59)), 'public, max-age=0, s-maxage=1');  // 1 s before the opening
  assert.equal(cacheControlFor(CFG, at(13, 0, 0)), IN);                                  // startMin itself is inside
  assert.equal(cacheControlFor(CFG, at(17, 59, 59)), IN);                                // last second of the window
  assert.equal(cacheControlFor(CFG, at(18, 0, 0)), OUT);                                 // endMin itself is outside
});

test('milliseconds: the remaining time is floored, so it can only be shorter', () => {
  assert.equal(ttlSecondsFor(CFG, new Date(Date.UTC(2026, 9, 10, 12, 59, 58, 500))), 1);  // 1.5 s left -> 1
  assert.equal(ttlSecondsFor(CFG, new Date(Date.UTC(2026, 9, 10, 12, 59, 59, 500))), 0);  // 0.5 s left -> 0, not cached
  assert.equal(ttlSecondsFor(CFG, new Date(Date.UTC(2026, 9, 10, 13, 0, 0, 0))), 0);      // inside, inTtl 0
});

test('after the close: the cap is the time until TOMORROW\'s opening', () => {
  const c = { startMin: 780, endMin: 1080, inTtl: 0, outTtl: 86400 };
  assert.equal(ttlSecondsFor(c, at(18, 0, 0)), 86400 - 18 * 3600 + 13 * 3600);   // 68400 s = 19 h
  assert.equal(ttlSecondsFor(c, at(23, 59, 59)), 1 + 13 * 3600);
  assert.equal(ttlSecondsFor(c, at(0, 0, 0)), 13 * 3600);
});

test('midnight wrap: window starting at 00:00 and window ending at 24:00', () => {
  const early = { startMin: 0, endMin: 60, inTtl: 0, outTtl: 14400 };
  assert.equal(ttlSecondsFor(early, at(0, 0, 0)), 0);
  assert.equal(ttlSecondsFor(early, at(1, 0, 0)), 14400);              // next opening is 23 h away
  assert.equal(ttlSecondsFor(early, at(23, 59, 59)), 1);               // 1 s to tomorrow's 00:00 opening
  const late = { startMin: 1200, endMin: 1440, inTtl: 0, outTtl: 14400 };
  assert.equal(ttlSecondsFor(late, at(19, 59, 59)), 1);
  assert.equal(ttlSecondsFor(late, at(23, 59, 59)), 0);                // still inside the window
  assert.equal(ttlSecondsFor(late, at(0, 0, 0)), 14400);
});

test('the cap never goes below 0 or to NaN; a smaller outTtl wins', () => {
  assert.equal(ttlSecondsFor({ ...CFG, outTtl: 30 }, at(12, 0, 0)), 30);
  assert.equal(ttlSecondsFor({ ...CFG, outTtl: 0 }, at(12, 0, 0)), 0);
  assert.equal(ttlSecondsFor({ startMin: NaN, endMin: 1080, inTtl: 0, outTtl: 14400 }, at(12, 0, 0)), 0);
  assert.equal(ttlSecondsFor({ ...CFG, outTtl: NaN }, at(12, 0, 0)), 0);
  assert.equal(ttlSecondsFor({ ...CFG, inTtl: -5 }, at(14, 0, 0)), 0);
  assert.equal(ttlSecondsFor({ ...CFG, inTtl: 60 }, at(14, 0, 0)), 60);
});

test('the cap is computed per invocation from the clock, with the config cached', async () => {
  const { handler, clock } = build({ time: at(12, 59, 0) });
  assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=60');
  clock.t = at(12, 59, 20);
  assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=40');
  clock.t = at(12, 59, 29);
  assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=31');
  assert.equal(clock.loads, 1, 'one S3 read for all three (config cached 30 s)');
});

test('a non-zero inTtl is used as given', () => {
  assert.equal(cacheControlFor({ ...CFG, inTtl: 60 }, at(14, 0)), 'public, max-age=0, s-maxage=60');
});

test('error statuses are not rewritten', async () => {
  const { handler, clock } = build({ time: at(0, 30) });
  for (const status of ['400', '404', '500', '503', 500]) {
    const r = await handler(ev(status, { 'cache-control': [{ key: 'Cache-Control', value: 'origin-value' }] }));
    assert.equal(cc(r), 'origin-value', String(status));
  }
  assert.equal(clock.loads, 0, 'errors do not even read the config');
});

test('only 200, 203, 204 and 206 are rewritten', async () => {
  const { handler } = build({ time: at(0, 30) });
  for (const status of ['200', '203', '204', '206', 200]) assert.equal(cc(await handler(ev(status))), OUT, String(status));
});

test('redirects, 304 and other statuses are left untouched', async () => {
  const { handler, clock } = build({ time: at(0, 30) });
  for (const status of ['201', '205', '301', '302', '304']) {
    const r = await handler(ev(status, {}));
    assert.equal(r.headers['cache-control'], undefined, status);
  }
  assert.equal(clock.loads, 0);
});

test('origin private, no-store or no-cache: response left untouched', async () => {
  for (const v of ['private', 'no-store', 'no-cache', 'public, no-cache', 'max-age=0, No-Store', 'private, max-age=60', 'no-cache="set-cookie"']) {
    const { handler } = build({ time: at(0, 30) });
    const r = await handler(ev('200', { 'cache-control': [{ key: 'Cache-Control', value: v }] }));
    assert.equal(cc(r), v, v);
  }
});

test('origin set-cookie: response left untouched, no Cache-Control added', async () => {
  const { handler } = build({ time: at(0, 30) });
  const r = await handler(ev('200', { 'set-cookie': [{ key: 'Set-Cookie', value: 'a=b' }] }));
  assert.equal(r.headers['cache-control'], undefined);
});

test('harmless origin Cache-Control (public, max-age) is replaced; look-alike words do not count', async () => {
  for (const v of ['public, max-age=60', 'max-age=0', 'x-private-ish=1', 'privately=1']) {
    const { handler } = build({ time: at(0, 30) });
    const r = await handler(ev('200', { 'cache-control': [{ key: 'Cache-Control', value: v }] }));
    assert.equal(cc(r), OUT, v);
  }
  assert.equal(originForbidsShared(undefined), false);
});

test('S3 read failure: fallback s-maxage=0, never a long TTL, nothing leaks into the log', async () => {
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  try {
    const { handler } = build({ time: at(0, 30), fail: true });
    assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL);
  } finally { console.log = orig; }
  assert.equal(FALLBACK_CACHE_CONTROL, IN);
  assert.ok(logs.length > 0);
  assert.ok(!logs.join('\n').includes('secret-name'), 'error message text must not be logged');
});

test('S3 client missing from the runtime: the function still loads, answers with s-maxage=0, logs one word', async () => {
  let present = true;
  try { await import('@aws-sdk/client-s3'); } catch { present = false; }
  if (present) return;   // the SDK happens to be installed here: this path cannot be exercised
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  let r;
  try { r = await realHandler(ev('200', {}, '/prices/a')); } finally { console.log = orig; }
  assert.equal(cc(r), FALLBACK_CACHE_CONTROL);
  assert.deepEqual(logs, ['s3-client-unavailable']);
});

test('a loader that reports s3-client-unavailable gives the fallback and logs only that word', async () => {
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  let r;
  try {
    const h = makeHandler({ loadText: async () => { throw Object.assign(new Error('Cannot find package @aws-sdk/client-s3 imported from /var/task/x'), { name: 's3-client-unavailable' }); }, now: () => at(0, 30) });
    r = await h(ev());
  } finally { console.log = orig; }
  assert.equal(cc(r), FALLBACK_CACHE_CONTROL);
  assert.deepEqual(logs, ['s3-client-unavailable']);
});

test('bad JSON, wrong shape and a bad default all give the fallback', async () => {
  const w = (o) => JSON.stringify({ default: { ...CFG, ...o } });
  const bad = ['not json', '', 'null', '[]', '"x"', '{}', '{"rules":"x"}', '{"rules":{}}',
    w({ startMin: 1080, endMin: 780 }),   // start after end (no overnight window)
    w({ startMin: 780, endMin: 780 }),    // empty window
    w({ startMin: -1 }), w({ endMin: 1441 }), w({ outTtl: -5 }),
    w({ outTtl: 31536001 }),
    w({ outTtl: '14400' }),               // string, not a number
    w({ inTtl: 1.5 }),
    JSON.stringify({ default: { startMin: 780, endMin: 1080, inTtl: 0 } })];  // outTtl missing
  for (const text of bad) {
    const { handler } = build({ text, time: at(0, 30) });
    assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL, text);
  }
  assert.notEqual(parseConfig(CFG_TEXT), null);
});

// ---- path rules
const W1 = { startMin: 480, endMin: 1020, inTtl: 0, outTtl: 14400 };      // 08:00-17:00
const W2 = { startMin: 600, endMin: 660, inTtl: 30, outTtl: 7200 };       // 10:00-11:00
const rule = (path, w = W1) => ({ path, ...w });
const pick = (cfg, uri) => selectWindow(parseConfig(JSON.stringify(cfg)), uri);

test('longest matching prefix wins', () => {
  const cfg = { rules: [rule('/a/*', W1), rule('/a/b/*', W2), rule('/*', { ...W1, outTtl: 1 })] };
  assert.deepEqual(pick(cfg, '/a/b/c'), W2);
  assert.deepEqual(pick(cfg, '/a/x'), W1);
  assert.equal(pick(cfg, '/zzz').outTtl, 1);
  const rev = { rules: [rule('/a/b/*', W2), rule('/a/*', W1)] };   // order in the file does not matter
  assert.deepEqual(pick(rev, '/a/b/c'), W2);
});

test('an exact path beats a prefix, even a longer-looking one', () => {
  const cfg = { rules: [rule('/a/b/*', W1), rule('/a/b/c', W2)] };
  assert.deepEqual(pick(cfg, '/a/b/c'), W2);
  assert.deepEqual(pick(cfg, '/a/b/d'), W1);
  assert.equal(pick({ rules: [rule('/a/b/c', W2)] }, '/a/b/c/'), null, 'exact means exact');
});

test('matching is case sensitive and /prices/* does not match /prices', () => {
  const cfg = { rules: [rule('/prices/*', W1)] };
  assert.equal(pick(cfg, '/Prices/x'), null);
  assert.equal(pick(cfg, '/prices'), null);
  assert.deepEqual(pick(cfg, '/prices/'), W1);
});

test('the query string is stripped before matching', () => {
  const cfg = { rules: [rule('/a/b', W2), rule('/p/*', W1)] };
  assert.deepEqual(pick(cfg, '/a/b?x=1&y=/p/z'), W2);
  assert.deepEqual(pick(cfg, '/p/q?x=/a/b'), W1);
});

test('URI variants of a rule path are never cached, not even through the default', async () => {
  const cfg = { rules: [rule('/prices/*', W1)], default: W2 };
  for (const u of ['//prices/a', '/prices//a', '/./prices/a', '/x/../prices/a', '/prices/.', '/prices/..', '/prices/a/.', '/%70rices/a', '/prices%2fa',
    '/prices/%61', '', 'prices/a', '/x/./y', '/x/../y', '/x//y', '/100%']) {
    assert.equal(pick(cfg, u), null, JSON.stringify(u));
    assert.equal(pick(cfg, `${u}?q=1`), null, `${u}?q=1`);
  }
  const { handler } = build({ text: JSON.stringify(cfg), time: at(0, 30) });
  assert.equal(cc(await handler(ev('200', {}, '//prices/a'))), FALLBACK_CACHE_CONTROL);
  assert.equal(cc(await handler(ev('200', {}, '/%70rices/a'))), FALLBACK_CACHE_CONTROL);
});

test('other unmatched variants (case, no slash) get the default, which is why the default should be the most restrictive window', () => {
  const cfg = { rules: [rule('/prices/*', W1)], default: W2 };
  assert.deepEqual(pick(cfg, '/Prices/a'), W2);
  assert.deepEqual(pick(cfg, '/prices'), W2);
  assert.deepEqual(pick(cfg, '/prices.html'), W2);
  assert.equal(pick({ rules: [rule('/prices/*', W1)] }, '/Prices/a'), null);
  assert.deepEqual(pick(cfg, '/prices/a.b..c/d'), W1);   // dots inside a name are not dot segments
});

test('no match: the default if there is one, otherwise null', () => {
  assert.deepEqual(pick({ rules: [rule('/a/*', W1)], default: W2 }, '/other'), W2);
  assert.equal(pick({ rules: [rule('/a/*', W1)] }, '/other'), null);
  assert.equal(pick({}, '/x'), null);
});

test('handler: no match and no default gives s-maxage=0', async () => {
  const text = JSON.stringify({ rules: [rule('/a/*')] });
  const { handler } = build({ text, time: at(0, 30) });
  assert.equal(cc(await handler(ev('200', {}, '/b/x'))), FALLBACK_CACHE_CONTROL);
  assert.equal(cc(await handler(ev('200', {}, '/a/x'))), OUT);  // 00:30 -> 08:00 is 27000 s away, capped by outTtl 14400
});

test('the cap is applied per matched rule, two paths at the same moment', async () => {
  // 12:00: /prices/* is inside its window, /rates/* is not (opens in 1 h, tomorrow's opening is far)
  const text = JSON.stringify({ rules: [
    { path: '/prices/*', startMin: 660, endMin: 780, inTtl: 0, outTtl: 14400 },
    { path: '/rates/*', startMin: 780, endMin: 900, inTtl: 0, outTtl: 14400 },
    { path: '/rates/old/*', startMin: 1080, endMin: 1200, inTtl: 0, outTtl: 600 }] });
  const { handler } = build({ text, time: at(12, 0) });
  assert.equal(cc(await handler(ev('200', {}, '/prices/x'))), IN);
  assert.equal(cc(await handler(ev('200', {}, '/rates/x'))), 'public, max-age=0, s-maxage=3600');
  assert.equal(cc(await handler(ev('200', {}, '/rates/old/x'))), 'public, max-age=0, s-maxage=600');
});

test('bad rules are skipped, good ones still work, and only the index is logged', async () => {
  const hidden = '/secret-path-do-not-log/*';
  const text = JSON.stringify({ rules: [
    rule('/ok/*'),                                                  // 0 ok
    { ...rule(hidden), startMin: 900, endMin: 100 },                 // 1 bad window
    { path: 'no-slash', ...W1 },                                     // 2
    { path: '/a*b', ...W1 },                                         // 3 star not at the end
    { path: '/a/**', ...W1 },                                        // 4
    { path: 42, ...W1 },                                             // 5
    { path: '/x y', ...W1 },                                         // 6 whitespace
    'junk', null,                                                    // 7, 8
    { path: '/ttl/*', startMin: 0, endMin: 10, inTtl: -1, outTtl: 5 }, // 9
    { path: '/ttl2/*', startMin: 0, endMin: 10, inTtl: 0, outTtl: 31536001 }, // 10
    { path: '/ok2', ...W1 }] });                                     // 11 ok
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  let cfg;
  try { cfg = parseConfig(text); } finally { console.log = orig; }
  assert.equal(cfg.rules.length, 2);
  assert.deepEqual(cfg.rules.map((r) => r.path), ['/ok/*', '/ok2']);
  for (const i of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) assert.ok(logs.some((l) => l.includes(`rule ${i} `)), `rule ${i}`);
  assert.ok(!logs.some((l) => l.includes('rule 0 ') || l.includes('rule 11 ')));
  assert.ok(!logs.join('\n').includes('secret-path') && !logs.join('\n').includes('no-slash'), 'rule content is never logged');
});

test('a malformed default is skipped but the rules still work', async () => {
  const text = JSON.stringify({ rules: [rule('/a/*')], default: { startMin: 5 } });
  const { handler } = build({ text, time: at(0, 30) });
  assert.equal(cc(await handler(ev('200', {}, '/a/x'))), OUT);
  assert.equal(cc(await handler(ev('200', {}, '/zzz'))), FALLBACK_CACHE_CONTROL);
});

test('a config over 256 KB or with more than 1000 rules is refused; only "config too large" is logged', async () => {
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  try {
    const many = (n) => JSON.stringify({ rules: Array.from({ length: n }, (_, i) => rule(`/p${i}/*`)) });
    assert.notEqual(parseConfig(many(1000)), null);
    assert.equal(parseConfig(many(1001)), null);
    const big = JSON.stringify({ default: W1, pad: 'x'.repeat(256 * 1024) });
    assert.equal(parseConfig(big), null);
    const { handler } = build({ text: big, time: at(0, 30) });
    assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL);
  } finally { console.log = orig; }
  assert.ok(logs.some((l) => l === 'config too large'));
  assert.ok(!logs.some((l) => l.includes('/p1/') || l.includes('xxxx')), 'content is never logged');
});

test('a UTF-8 byte order mark in front of the JSON is ignored', () => {
  const c = parseConfig('\uFEFF' + JSON.stringify({ rules: [rule('/a/*')] }));
  assert.equal(c.rules.length, 1);
});

test('TTLs above 86400 (the cache policy MaxTTL) make the rule malformed; 86400 is fine', () => {
  const logs = [];
  const orig = console.log; console.log = (...a) => logs.push(a.join(' '));
  let c;
  try { c = parseConfig(JSON.stringify({ rules: [rule('/a/*', { ...W1, outTtl: 86400 }), rule('/b/*', { ...W1, outTtl: 86401 }), rule('/c/*', { ...W1, inTtl: 86401 })] })); }
  finally { console.log = orig; }
  assert.deepEqual(c.rules.map((r) => r.path), ['/a/*']);
  assert.ok(logs.some((l) => l.includes('rule 1 ')) && logs.some((l) => l.includes('rule 2 ')));
});

test('the whole config is cached once for different paths', async () => {
  const text = JSON.stringify({ rules: [rule('/a/*'), rule('/b/*', W2)] });
  const { handler, clock } = build({ text, time: at(0, 30) });
  await handler(ev('200', {}, '/a/1')); await handler(ev('200', {}, '/b/1')); await handler(ev('200', {}, '/c/1'));
  assert.equal(clock.loads, 1);
});

test('the config is cached for 30 s, then read again', async () => {
  const { handler, clock } = build({ time: at(0, 30, 0) });
  await handler(ev());
  clock.t = at(0, 30, 29); await handler(ev());
  assert.equal(clock.loads, 1);
  clock.text = JSON.stringify({ default: { ...CFG, outTtl: 60 } });
  clock.t = at(0, 30, 31); assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=60');
  assert.equal(clock.loads, 2);
});

test('after the cache expires a failing read gives the fallback, not the old long TTL', async () => {
  const { handler, clock } = build({ time: at(0, 30, 0) });
  assert.equal(cc(await handler(ev())), OUT);
  clock.fail = true;
  clock.t = at(0, 30, 10); assert.equal(cc(await handler(ev())), OUT, 'still inside the 30 s memory cache');
  clock.t = at(0, 30, 31); assert.equal(cc(await handler(ev())), FALLBACK_CACHE_CONTROL);
});

test('a failure is remembered for a few seconds only, then S3 is tried again', async () => {
  const { handler, clock } = build({ time: at(0, 30, 0), fail: true });
  await handler(ev()); clock.t = at(0, 30, 3); await handler(ev());
  assert.equal(clock.loads, 1);
  clock.fail = false; clock.t = at(0, 30, 6);
  assert.equal(cc(await handler(ev())), OUT);
  assert.equal(clock.loads, 2);
});

test('the same config is evaluated against the clock on every request (window opens without a config reload)', async () => {
  const { handler, clock } = build({ time: at(12, 59, 50) });
  assert.equal(cc(await handler(ev())), 'public, max-age=0, s-maxage=10');
  clock.t = at(13, 0, 5);
  assert.equal(cc(await handler(ev())), IN);
  assert.equal(clock.loads, 1);
});

test('other response headers are kept', async () => {
  const { handler } = build();
  const r = await handler(ev('200', { 'content-type': [{ key: 'Content-Type', value: 'text/plain' }] }));
  assert.equal(r.headers['content-type'][0].value, 'text/plain');
});
