import test from 'node:test';
import assert from 'node:assert/strict';
import { loadRoute, event } from './helpers.mjs';

const STORE = {
  'shop.example.com': 'origin-a.example.net',
  'blog.example.com': 'origin-b.example.net',
  'bad-colon': 'origin-a.example.net:8443',
  'bad-ip': '192.0.2.10',
  'bad-upper': 'Origin-A.example.net',
  'bad-empty': '',
  'bad-single-label': 'localhost',
};

function host(value) { return event('host', value); }

test('valid route: updates the origin and hostHeader and returns the request', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  const ev = host('shop.example.com');
  const res = await handler(ev);
  assert.equal(res, ev.request);
  assert.deepEqual(calls.updates, [{ domainName: 'origin-a.example.net', hostHeader: 'origin-a.example.net' }]);
});

test('two hosts route to two different backends', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  await handler(host('shop.example.com'));
  await handler(host('blog.example.com'));
  assert.deepEqual(calls.updates.map((u) => u.domainName), ['origin-a.example.net', 'origin-b.example.net']);
});

test('unknown host: 404 and the origin is never touched', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  const res = await handler(host('nobody.example.com'));
  assert.equal(res.statusCode, 404);
  assert.equal(calls.updates.length, 0);
});

test('missing routing attribute: 404, no store lookup', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  for (const ev of [event('host', undefined), host('')]) {
    const res = await handler(ev);
    assert.equal(res.statusCode, 404);
  }
  assert.equal(calls.reads.length, 0);
  assert.equal(calls.updates.length, 0);
});

test('host only a port or a dot: 404', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  for (const v of [':443', '.']) {
    assert.equal((await handler(host(v))).statusCode, 404);
  }
  assert.equal(calls.updates.length, 0);
});

for (const [name, value] of [
  ['bad-colon', 'colon in value'],
  ['bad-ip', 'IP address'],
  ['bad-upper', 'upper-case value'],
  ['bad-empty', 'empty value'],
  ['bad-single-label', 'single-label name'],
]) {
  test(`bad backend value (${value}): 500 and no fall-through`, async () => {
    const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
    const res = await handler(host(name));
    assert.equal(res.statusCode, 500);
    assert.equal(res.headers, undefined);
    assert.equal(calls.updates.length, 0, 'must not call updateRequestOrigin');
    assert.notEqual(res.uri, '/same.json', 'must not return the request (default origin)');
    assert.equal(res.method, undefined, 'a reply, not the request');
  });
}

test('header normalization: case, port, trailing dot', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  for (const v of ['SHOP.EXAMPLE.COM', 'shop.example.com:443', 'shop.example.com.', 'Shop.Example.Com.:8443']) {
    calls.updates.length = 0;
    const res = await handler(host(v));
    assert.equal(res.statusCode, undefined, `${v} should route`);
    assert.equal(calls.updates.length, 1, v);
    assert.equal(calls.updates[0].domainName, 'origin-a.example.net');
  }
});

test('normalization does not let a crafted host reach a different key', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host' });
  for (const v of ['shop.example.com.evil.test', 'evil.test:shop.example.com', 'shop.example.com/..', 'shop.example.com@evil.test']) {
    const res = await handler(host(v));
    assert.equal(res.statusCode, 404, v);
  }
  assert.equal(calls.updates.length, 0);
});

test('a store read error is not swallowed: the handler rejects and never returns the request', async () => {
  const { handler, calls } = loadRoute({ store: STORE, attribute: 'host', getThrows: true });
  await assert.rejects(() => handler(host('shop.example.com')), /store unavailable/);
  assert.equal(calls.updates.length, 0);
});

test('updateRequestOrigin throwing is not swallowed: no fall-through to the default origin', async () => {
  const { handler } = loadRoute({ store: STORE, attribute: 'host', updateThrows: true });
  await assert.rejects(() => handler(host('shop.example.com')), /bad origin/);
});

test('x-backend attribute (default): routes on the header, ignores Host', async () => {
  const { handler, calls } = loadRoute({ store: { 'route-a': 'origin-a.example.net' } });
  const ev = event('x-backend', 'route-a');
  ev.request.headers.host = { value: 'dexample.cloudfront.net' };
  const res = await handler(ev);
  assert.equal(res, ev.request);
  assert.equal(calls.updates[0].domainName, 'origin-a.example.net');
  // Host alone is not a key in this mode
  const only = event('host', 'route-a');
  assert.equal((await handler(only)).statusCode, 404);
});

test('the request value is only ever used as a key, never as the origin', async () => {
  const { handler, calls } = loadRoute({ store: { 'route-a': 'origin-a.example.net' } });
  const res = await handler(event('x-backend', 'attacker.example.org'));
  assert.equal(res.statusCode, 404);
  assert.equal(calls.updates.length, 0);
});
