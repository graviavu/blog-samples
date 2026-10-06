import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root, readPolicies } from './helpers.mjs';

const read = (f) => readFileSync(join(root, f), 'utf8');
const main = read('template.yaml');
const edge = read('template-lambda-edge.yaml');

test('test cache policies have the TTLs verify.sh and the mock expect', () => {
  const t = readPolicies();
  assert.deepEqual(t, { orig: [0, 0, 31536000], b: [30, 60, 3600], m0: [0, 20, 60], defhi: [0, 60, 20] });
  const verify = read('verify.sh');
  for (const [name, [a, b, c]] of Object.entries(t)) {
    assert.ok(verify.includes(`POLICY_${name}="${a} ${b} ${c}"`), `verify.sh POLICY_${name} must be "${a} ${b} ${c}"`);
  }
});

test('the post policy A equivalent is the managed policy UseOriginCacheControlHeaders TTLs, policy B is 30/60/3600', () => {
  const t = readPolicies();
  assert.deepEqual(t.orig, [0, 0, 31536000]);
  assert.deepEqual(t.b, [30, 60, 3600]);
});

test('every stack resource that can be tagged is tagged sample=cloudfront-time-window-caching, and so are the stacks', () => {
  assert.ok(main.includes('sample, Value: cloudfront-time-window-caching'));
  assert.ok(edge.includes('sample, Value: cloudfront-time-window-caching'));
  assert.ok(read('deploy.sh').includes('--tags sample=cloudfront-time-window-caching'));
  assert.ok(read('teardown.sh').includes('"cloudfront-time-window-caching"'));
});

test('the test origin is IAM-protected and only CloudFront for this distribution may invoke it', () => {
  for (const t of [main, edge]) {
    assert.ok(!/AuthType:\s*NONE/.test(t), 'no public function URL');
    assert.ok(!/Principal:\s*['"]?\*/.test(t), 'no wildcard principal');
    assert.ok(!/Resource:\s*['"]?\*['"]?\s*$/m.test(t), 'no wildcard resource');
  }
  assert.ok(/AuthType: AWS_IAM/.test(main));
  for (const t of [main, edge]) {
    assert.equal((t.match(/Principal: cloudfront\.amazonaws\.com/g) || []).length, 2, 'two permission statements');
    assert.equal((t.match(/SourceArn: !Sub 'arn:\$\{AWS::Partition\}:cloudfront::\$\{AWS::AccountId\}:distribution\//g) || []).length, 2);
  }
  assert.ok(/OriginAccessControlOriginType: lambda/.test(main));
});

test('test behaviors and the default-above-max policy are off by default; the function is runtime 2.0', () => {
  assert.match(main, /EnableTestBehaviors:\n\s+Type: String\n\s+Default: 'false'/);
  assert.match(main, /TryDefaultAboveMax:\n\s+Type: String\n\s+Default: 'false'/);
  assert.equal((main.match(/Runtime: cloudfront-js-2\.0/g) || []).length, 2);
  assert.ok(!/cloudfront-js-1\.0/.test(main));
});

test('the main template is us-east-1 only, has a security headers policy and no secrets', () => {
  assert.ok(main.includes('us-east-1') && edge.includes('us-east-1'));
  assert.ok(main.includes('StrictTransportSecurity'));
  assert.ok(!/(secret|password|token)\s*[:=]/i.test(main + edge));
});

test('the window cache policy keys on the slot only: query slot or header x-cache-slot', () => {
  assert.match(main, /QueryStrings: \[slot\]/);
  assert.match(main, /Headers: \[x-cache-slot\]/);
  assert.match(main, /MinTTL: !Ref ClosedMinTtl/);
});

test('the edge template has no data store and no environment variables', () => {
  assert.ok(!/KeyValueStore|DynamoDB|Environment:/.test(edge));
});
