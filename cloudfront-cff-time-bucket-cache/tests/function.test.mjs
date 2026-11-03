// Unit tests of the CloudFront Function logic and of the template. No AWS, no dependencies: node --test tests/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, templateCode, render, load } from './lib/render.mjs';

const T = (h, m = 0, s = 0, day = 10) => Date.UTC(2026, 9, day, h, m, s);
const fn = (p, now) => load(render(templateCode(), { StartHour: 8, EndHour: 17, BucketSeconds: 60, ...p }), now);
const run = (p, now, headers = {}) => {
  const req = { method: 'GET', uri: '/probe.txt', headers: { ...headers } };
  return fn(p, now).handler({ request: req }).headers;
};

test('inside the window the header is the time bucket', () => {
  const now = T(12, 0, 30);
  assert.equal(run({}, now)['x-cache-bust'].value, String(Math.floor(now / 1000 / 60)));
});
test('same bucket gives the same value, the next second of the next bucket a new one', () => {
  const a = run({}, T(12, 0, 0))['x-cache-bust'].value;
  const b = run({}, T(12, 0, 59))['x-cache-bust'].value;
  const c = run({}, T(12, 1, 0))['x-cache-bust'].value;
  assert.equal(a, b);
  assert.notEqual(b, c);
  assert.equal(Number(c), Number(b) + 1);
});
test('bucket length follows BucketSeconds and is never 0', () => {
  const now = T(9, 0, 0);
  assert.equal(run({ BucketSeconds: 300 }, now)['x-cache-bust'].value, String(Math.floor(now / 1000 / 300)));
  assert.equal(run({ BucketSeconds: 300 }, now + 299000)['x-cache-bust'].value, run({ BucketSeconds: 300 }, now)['x-cache-bust'].value);
  assert.notEqual(run({ BucketSeconds: 300 }, now + 300000)['x-cache-bust'].value, run({ BucketSeconds: 300 }, now)['x-cache-bust'].value);
  assert.ok(Number(run({ BucketSeconds: 1 }, now)['x-cache-bust'].value) > 0);
});
test('window edges: start inclusive, end exclusive', () => {
  assert.equal(run({}, T(7, 59, 59))['x-cache-bust'], undefined);
  assert.ok(run({}, T(8, 0, 0))['x-cache-bust']);
  assert.ok(run({}, T(16, 59, 59))['x-cache-bust']);
  assert.equal(run({}, T(17, 0, 0))['x-cache-bust'], undefined);
});
test('outside the window nothing is set', () => {
  for (const h of [0, 3, 7, 17, 20, 23]) assert.equal(run({}, T(h, 30))['x-cache-bust'], undefined, 'hour ' + h);
});
test('a viewer-supplied x-cache-bust is overwritten inside the window', () => {
  const now = T(12);
  const h = run({}, now, { 'x-cache-bust': { value: 'attacker' } });
  assert.equal(h['x-cache-bust'].value, String(Math.floor(now / 1000 / 60)));
});
test('a viewer-supplied x-cache-bust is deleted outside the window', () => {
  const h = run({}, T(20), { 'x-cache-bust': { value: 'attacker' }, host: { value: 'x' } });
  assert.equal('x-cache-bust' in h, false);
  assert.equal(h.host.value, 'x');
});
test('other headers and the uri are left alone', () => {
  const req = { method: 'GET', uri: '/a/b.txt', headers: { accept: { value: '*/*' } } };
  const out = fn({}, T(12)).handler({ request: req });
  assert.equal(out.uri, '/a/b.txt');
  assert.equal(out.headers.accept.value, '*/*');
});
test('window across midnight (22 to 6)', () => {
  const p = { StartHour: 22, EndHour: 6 };
  for (const h of [22, 23, 0, 5]) assert.ok(run(p, T(h, 10))['x-cache-bust'], 'hour ' + h);
  for (const h of [6, 7, 12, 21]) assert.equal(run(p, T(h, 10))['x-cache-bust'], undefined, 'hour ' + h);
  assert.equal(run(p, T(5, 59, 59))['x-cache-bust'] !== undefined, true);
  assert.equal(run(p, T(6, 0, 0))['x-cache-bust'], undefined);
});
test('window to midnight (EndHour 24) and the whole day', () => {
  assert.ok(run({ StartHour: 20, EndHour: 24 }, T(23, 59, 59))['x-cache-bust']);
  assert.equal(run({ StartHour: 20, EndHour: 24 }, T(0, 0, 0, 11))['x-cache-bust'], undefined);
  for (const h of [0, 11, 23]) assert.ok(run({ StartHour: 0, EndHour: 24 }, T(h))['x-cache-bust']);
});
test('a one-hour window', () => {
  assert.ok(run({ StartHour: 10, EndHour: 11 }, T(10, 59, 59))['x-cache-bust']);
  assert.equal(run({ StartHour: 10, EndHour: 11 }, T(11))['x-cache-bust'], undefined);
});
test('malformed settings fall back to "no bust" and the handler still deletes the viewer header', () => {
  const { bucketFor } = fn({}, T(12));
  const good = { startHour: 8, endHour: 17, bucketSeconds: 60 };
  assert.equal(bucketFor(good, T(12)) !== '', true);
  const bad = [
    { startHour: 'abc' }, { endHour: 'abc' }, { bucketSeconds: 'abc' }, { startHour: -1 }, { startHour: 24 }, { endHour: 25 },
    { endHour: -1 }, { bucketSeconds: 0 }, { bucketSeconds: -5 }, { bucketSeconds: 86401 }, { startHour: 1.5 }, { bucketSeconds: 0.5 },
    { startHour: 10, endHour: 10 }, { startHour: null }, { bucketSeconds: Infinity }, { startHour: NaN }, { endHour: undefined },
  ];
  for (const b of bad) assert.equal(bucketFor({ ...good, ...b }, T(12)), '', JSON.stringify(b));
  // values that are still valid JavaScript when rendered into the code (CloudFormation limits stop most of these earlier)
  for (const p of [{ StartHour: 'NaN' }, { BucketSeconds: 0 }, { BucketSeconds: -5 }, { StartHour: 10, EndHour: 10 }, { BucketSeconds: 'Infinity' }, { StartHour: 25 }]) {
    const h = run(p, T(12), { 'x-cache-bust': { value: 'x' } });
    assert.equal('x-cache-bust' in h, false, JSON.stringify(p));
  }
});
test('bucketFor with a bad clock value gives no bucket', () => {
  const { bucketFor } = fn({}, T(12));
  const cfg = { startHour: 8, endHour: 17, bucketSeconds: 60 };
  assert.equal(bucketFor(cfg, NaN), '');
  assert.equal(bucketFor(cfg, undefined), '');
  assert.equal(bucketFor(cfg, '12'), '');
});

// ---------------------------------------------------------------- template checks (text based, no yaml library)
const tpl = readFileSync(join(ROOT, 'cfn', 'stack.yaml'), 'utf8');
test('function/time-bucket.js is exactly the code in the template', () => {
  assert.equal(readFileSync(join(ROOT, 'function', 'time-bucket.js'), 'utf8'), templateCode());
});
test('the function code has no placeholder other than the three parameters, and no template literal', () => {
  const found = [...templateCode().matchAll(/\$\{([^}]*)\}/g)].map((m) => m[1]).sort();
  assert.deepEqual(found, ['BucketSeconds', 'EndHour', 'StartHour']);
  assert.equal(templateCode().includes('`'), false);
});
test('the function code is small (CloudFront Functions allow 10 KB)', () => {
  assert.ok(Buffer.byteLength(templateCode()) < 4000);
});
test('template: runtime 2.0, viewer-request, header whitelist with x-cache-bust, min TTL 0, OAC, no public access', () => {
  assert.match(tpl, /Runtime: cloudfront-js-2\.0/);
  assert.match(tpl, /EventType: viewer-request/);
  assert.match(tpl, /HeaderBehavior: whitelist\n\s+Headers:\n\s+- x-cache-bust/);
  assert.match(tpl, /MinTTL: 0\b/);
  assert.match(tpl, /DefaultTTL: !Ref LongTtl/);
  assert.match(tpl, /MaxTTL: !Ref LongTtl/);
  assert.match(tpl, /OriginAccessControlOriginType: s3/);
  assert.match(tpl, /SigningBehavior: always/);
  assert.match(tpl, /BlockPublicAcls: true/);
  assert.match(tpl, /'aws:SecureTransport': 'false'/);
  assert.match(tpl, /AutoPublish: true/);
});
test('template: parameter limits match the function checks', () => {
  assert.match(tpl, /StartHour:[\s\S]*?MinValue: 0\n\s+MaxValue: 23/);
  assert.match(tpl, /EndHour:[\s\S]*?MinValue: 0\n\s+MaxValue: 24/);
  assert.match(tpl, /BucketSeconds:[\s\S]*?MinValue: 1\n\s+MaxValue: 86400/);
  assert.match(tpl, /Assert: !Not \[!Equals \[!Ref StartHour, !Ref EndHour\]\]/);
});
test('template: no account id, access key or real host in the text', () => {
  assert.equal(/(^|[^0-9])[0-9]{12}([^0-9]|$)/.test(tpl), false);
  assert.equal(/AKIA|ASIA|\.cloudfront\.net|lambda-url/.test(tpl), false);
});
