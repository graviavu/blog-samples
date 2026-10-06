import test from 'node:test';
import assert from 'node:assert/strict';
import { loadSlot, loadOrigin, urlEvent, viewerEvent, win, T } from './helpers.mjs';

const WINDOW = { startMin: 810, endMin: 1200, slotSeconds: 5, rev: 1 }; // 13:30 to 20:00 UTC
const STORE = { window: win(WINDOW) };
const slotOf = async (opts, ev = viewerEvent()) => {
  const { handler } = loadSlot(opts);
  const res = await handler(ev);
  return opts.carrier === 'header' ? res.headers['x-cache-slot'].value : res.querystring.slot.value;
};

test('before the open: pre-<date>-r<rev>', async () => {
  assert.equal(await slotOf({ store: STORE, now: T('2026-10-05T08:00:00Z') }), 'pre-2026-10-05-r1');
  assert.equal(await slotOf({ store: STORE, now: T('2026-10-05T13:29:59Z') }), 'pre-2026-10-05-r1');
  assert.equal(await slotOf({ store: STORE, now: T('2026-10-05T00:00:00Z') }), 'pre-2026-10-05-r1');
});

test('after the close: post-<date>-r<rev>', async () => {
  assert.equal(await slotOf({ store: STORE, now: T('2026-10-05T20:00:00Z') }), 'post-2026-10-05-r1');
  assert.equal(await slotOf({ store: STORE, now: T('2026-10-05T23:59:59Z') }), 'post-2026-10-05-r1');
});

test('in the window: w<epoch/slotSeconds>, open edge included, close edge excluded', async () => {
  const at = (iso) => slotOf({ store: STORE, now: T(iso) });
  assert.equal(await at('2026-10-05T13:30:00Z'), 'w' + Math.floor(T('2026-10-05T13:30:00Z') / 5000));
  assert.equal(await at('2026-10-05T19:59:59Z'), 'w' + Math.floor(T('2026-10-05T19:59:59Z') / 5000));
  assert.match(await at('2026-10-05T14:00:00Z'), /^w\d+$/);
});

test('slot changes every slotSeconds and never repeats across days', async () => {
  const a = await slotOf({ store: STORE, now: T('2026-10-05T14:00:00Z') });
  const sameSlot = await slotOf({ store: STORE, now: T('2026-10-05T14:00:04Z') });
  const next = await slotOf({ store: STORE, now: T('2026-10-05T14:00:05Z') });
  const tomorrow = await slotOf({ store: STORE, now: T('2026-10-06T14:00:00Z') });
  assert.equal(a, sameSlot);
  assert.notEqual(a, next);
  assert.notEqual(a, tomorrow);
  const ten = { window: win({ ...WINDOW, slotSeconds: 10 }) };
  assert.equal(await slotOf({ store: ten, now: T('2026-10-05T14:00:00Z') }), await slotOf({ store: ten, now: T('2026-10-05T14:00:09Z') }));
});

test('pre-open and post-close keys differ on the same date (the flaw of the first key is fixed)', async () => {
  const pre = await slotOf({ store: STORE, now: T('2026-10-05T08:00:00Z') });
  const post = await slotOf({ store: STORE, now: T('2026-10-05T21:00:00Z') });
  assert.notEqual(pre, post);
  assert.match(pre, /^pre-/);
  assert.match(post, /^post-/);
});

test('the closed key changes with the date and with rev, and the in-window key does not carry rev', async () => {
  const closed = (store, iso) => slotOf({ store, now: T(iso) });
  const r1 = await closed({ window: win(WINDOW) }, '2026-10-05T08:00:00Z');
  const r2 = await closed({ window: win({ ...WINDOW, rev: 2 }) }, '2026-10-05T08:00:00Z');
  const nextDay = await closed({ window: win(WINDOW) }, '2026-10-06T08:00:00Z');
  assert.notEqual(r1, r2);
  assert.equal(r2, 'pre-2026-10-05-r2');
  assert.notEqual(r1, nextDay);
  assert.equal(await closed({ window: win({ ...WINDOW, rev: 0 }) }, '2026-10-05T08:00:00Z'), 'pre-2026-10-05-r0');
  assert.equal(await closed({ window: win({ startMin: 810, endMin: 1200, slotSeconds: 5 }) }, '2026-10-05T08:00:00Z'), 'pre-2026-10-05-r0', 'rev defaults to 0 as in the post');
});

// ---- fail closed
const NOW = T('2026-10-05T08:00:00Z');
const FALLBACK = 'f' + Math.floor(NOW / 5000);

test('missing key, store error: fail closed to the short fallback slot, request still returned', async () => {
  for (const opts of [{ store: {} }, { store: STORE, getThrows: true }]) {
    const { handler } = loadSlot({ ...opts, now: NOW });
    const ev = viewerEvent();
    const res = await handler(ev);
    assert.equal(res, ev.request, 'returns the request, never throws');
    assert.equal(res.querystring.slot.value, FALLBACK);
  }
});

const INVALID = {
  'not JSON': 'not-json',
  'empty string': '',
  'JSON null': 'null',
  'a number': '5',
  'an array': '[1,2]',
  'a string': '"x"',
  'empty object': '{}',
  'string minutes': win({ startMin: '810', endMin: '1200', slotSeconds: 5, rev: 1 }),
  'float minutes': win({ startMin: 810.5, endMin: 1200, slotSeconds: 5, rev: 1 }),
  'negative start': win({ startMin: -1, endMin: 1200, slotSeconds: 5, rev: 1 }),
  'start 1440': win({ startMin: 1440, endMin: 1440, slotSeconds: 5, rev: 1 }),
  'end above 1440': win({ startMin: 0, endMin: 1441, slotSeconds: 5, rev: 1 }),
  'end 0': win({ startMin: 0, endMin: 0, slotSeconds: 5, rev: 1 }),
  'start equals end': win({ startMin: 600, endMin: 600, slotSeconds: 5, rev: 1 }),
  'slotSeconds 0': win({ ...WINDOW, slotSeconds: 0 }),
  'slotSeconds too large': win({ ...WINDOW, slotSeconds: 3601 }),
  'slotSeconds float': win({ ...WINDOW, slotSeconds: 2.5 }),
  'negative rev': win({ ...WINDOW, rev: -1 }),
  'huge rev': win({ ...WINDOW, rev: 1000000 }),
  'rev as string': win({ ...WINDOW, rev: '1' }),
  'null field': '{"startMin":null,"endMin":1200,"slotSeconds":5,"rev":1}',
};
for (const [name, raw] of Object.entries(INVALID)) {
  test(`invalid record (${name}) fails closed to the fallback slot`, async () => {
    assert.equal(await slotOf({ store: { window: raw }, now: NOW }), FALLBACK);
  });
}

test('a window across midnight (startMin > endMin) is rejected, not guessed: fallback slot at any time of day', async () => {
  const across = { window: win({ startMin: 1380, endMin: 60, slotSeconds: 5, rev: 1 }) };
  for (const iso of ['2026-10-05T23:30:00Z', '2026-10-05T00:30:00Z', '2026-10-05T12:00:00Z']) {
    assert.match(await slotOf({ store: across, now: T(iso) }), /^f\d+$/, iso);
  }
});

test('the fallback slot is short and changes: staleness stays bounded', async () => {
  const a = await slotOf({ store: {}, now: T('2026-10-05T08:00:00Z') });
  const b = await slotOf({ store: {}, now: T('2026-10-05T08:00:05Z') });
  assert.notEqual(a, b);
});

// ---- normalization, query carrier
test('query carrier: sets slot, replaces a viewer-supplied slot and multiple values, keeps other parameters, drops the header', async () => {
  const { handler } = loadSlot({ store: STORE, now: NOW });
  const ev = viewerEvent({
    query: { slot: { value: 'w1', multiValue: [{ value: 'w1' }, { value: 'evil' }] }, other: { value: '1' } },
    headers: { 'x-cache-slot': { value: 'evil' } },
  });
  const res = await handler(ev);
  assert.equal(res, ev.request);
  assert.deepEqual(res.querystring.slot, { value: 'pre-2026-10-05-r1' });
  assert.deepEqual(res.querystring.other, { value: '1' }, 'other query strings are left alone (the cache policy keeps them out of the key)');
  assert.equal(res.headers['x-cache-slot'], undefined);
});

test('query carrier: works when the event has no querystring object', async () => {
  const { handler } = loadSlot({ store: STORE, now: NOW });
  const ev = viewerEvent();
  delete ev.request.querystring;
  assert.equal((await handler(ev)).querystring.slot.value, 'pre-2026-10-05-r1');
});

// ---- normalization, header carrier
test('header carrier: sets x-cache-slot, replaces a viewer-supplied header, drops a viewer slot query', async () => {
  const { handler } = loadSlot({ store: STORE, now: NOW, carrier: 'header' });
  const ev = viewerEvent({ query: { slot: { value: 'evil' }, other: { value: '1' } }, headers: { 'x-cache-slot': { value: 'evil', multiValue: [{ value: 'evil' }] } } });
  const res = await handler(ev);
  assert.deepEqual(res.headers['x-cache-slot'], { value: 'pre-2026-10-05-r1' });
  assert.equal(res.querystring.slot, undefined);
  assert.deepEqual(res.querystring.other, { value: '1' });
});

test('header carrier: same slot values as the query carrier', async () => {
  for (const iso of ['2026-10-05T08:00:00Z', '2026-10-05T14:00:00Z', '2026-10-05T21:00:00Z']) {
    assert.equal(await slotOf({ store: STORE, now: T(iso), carrier: 'header' }), await slotOf({ store: STORE, now: T(iso) }));
  }
});

test('the function reads exactly the key "window" as JSON', async () => {
  const { handler, reads } = loadSlot({ store: STORE, now: NOW });
  await handler(viewerEvent());
  assert.deepEqual(reads, [['window', { format: 'json' }]]);
});

// ---- the origin accepts every slot value the function can produce (the allow-list must not drop real slots)
test('every slot the function produces passes the origin allow-list', async () => {
  const origin = loadOrigin();
  const slots = [];
  for (const iso of ['2026-10-05T08:00:00Z', '2026-10-05T14:00:00Z', '2026-10-05T21:00:00Z']) {
    slots.push(await slotOf({ store: STORE, now: T(iso) }), await slotOf({ store: {}, now: T(iso) }));
  }
  slots.push(await slotOf({ file: 'slot-legacy.js', store: STORE, now: T('2026-10-05T08:00:00Z') }));
  for (const s of slots) {
    const res = await origin(urlEvent('/x/none', { query: { slot: s } }));
    assert.equal(JSON.parse(res.body).slot, s, s);
  }
});

// ---- legacy function (test only)
test('legacy key: identical before the open and after the close (the flaw), distinct per date', async () => {
  const legacy = (iso) => slotOf({ file: 'slot-legacy.js', store: STORE, now: T(iso) });
  const pre = await legacy('2026-10-05T08:00:00Z');
  const post = await legacy('2026-10-05T21:00:00Z');
  assert.equal(pre, 'closed-2026-10-05');
  assert.equal(pre, post);
  assert.notEqual(pre, await legacy('2026-10-06T08:00:00Z'));
  assert.match(await legacy('2026-10-05T14:00:00Z'), /^w\d+$/);
});

test('legacy key also fails closed on a bad record', async () => {
  assert.equal(await slotOf({ file: 'slot-legacy.js', store: { window: 'x' }, now: NOW }), FALLBACK);
  assert.equal(await slotOf({ file: 'slot-legacy.js', store: {}, now: NOW }), FALLBACK);
});
