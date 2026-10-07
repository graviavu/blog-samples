import test from 'node:test';
import assert from 'node:assert/strict';
import { readSource } from './helpers.mjs';

function loadEdge() {
  const module = { exports: {} };
  new Function('module', 'exports', readSource('edge-origin-request.js'))(module, module.exports);
  return module.exports.handler;
}

function edgeEvent(headers) {
  return { Records: [{ cf: { request: { uri: '/x', headers, origin: { custom: { domainName: 'default.example.net' } } } } }] };
}

function run(handler, ev) {
  return new Promise((resolve) => handler(ev, {}, (err, out) => resolve({ err, out })));
}

test('edge: known key retargets the origin and Host', async () => {
  const { out } = await run(loadEdge(), edgeEvent({ 'x-backend': [{ key: 'X-Backend', value: 'Route-A:443' }] }));
  assert.equal(out.origin.custom.domainName, 'origin-a.example.net');
  assert.equal(out.headers.host[0].value, 'origin-a.example.net');
});

test('edge: unknown or missing key answers 404, no fall-through', async () => {
  for (const headers of [{ 'x-backend': [{ key: 'X-Backend', value: 'nope' }] }, {}, { 'x-backend': [{ key: 'X-Backend', value: 'constructor' }] }]) {
    const { out } = await run(loadEdge(), edgeEvent(headers));
    assert.equal(out.status, '404');
    assert.equal(out.origin, undefined);
  }
});

test('edge: a known key on a non-custom origin answers 500 and never passes the request on', async () => {
  for (const origin of [{ s3: { domainName: 'bucket.example.net' } }, undefined]) {
    const ev = edgeEvent({ 'x-backend': [{ key: 'X-Backend', value: 'route-a' }] });
    ev.Records[0].cf.request.origin = origin;
    const { out } = await run(loadEdge(), ev);
    assert.equal(out.status, '500');
    assert.equal(out.uri, undefined);
  }
});

test('probe: returns the raw Host value and never an origin', () => {
  const handler = new Function(`${readSource('probe.js')}\nreturn handler;`)();
  const res = handler({ request: { headers: { host: { value: 'Example.COM:443' } } } });
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['x-seen-host'].value, 'Example.COM:443');
  assert.equal(handler({ request: { headers: {} } }).headers['x-seen-host'].value, '(none)');
});
