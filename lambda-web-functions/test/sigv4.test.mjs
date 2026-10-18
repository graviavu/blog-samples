// Tests of worker/sigv4.mjs against the examples published in the AWS Signature Version 4 documentation.
import test from 'node:test';
import assert from 'node:assert/strict';
import { signRequest, signingKey, sha256Hex } from '../worker/sigv4.mjs';

const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join('');
// The documentation's published example key pair (not a real credential).
const EXAMPLE_KEY = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';
const EXAMPLE_ID = 'AKIDEXAMPLE';

test('derived signing key (AWS docs, iam example)', async () => {
  const k = await signingKey(EXAMPLE_KEY, '20150830', 'us-east-1', 'iam');
  assert.equal(hex(k), 'c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9');
});

test('sha256 of the empty string', async () => {
  assert.equal(await sha256Hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
});

test('AWS test suite vector get-vanilla', async () => {
  const r = await signRequest({
    method: 'GET', url: 'https://example.amazonaws.com/', accessKeyId: EXAMPLE_ID, secretAccessKey: EXAMPLE_KEY,
    region: 'us-east-1', service: 'service', includeContentSha256: false, now: new Date('2015-08-30T12:36:00Z'),
  });
  assert.equal(r.signature, '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31');
  assert.match(r.headers.authorization, /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/20150830\/us-east-1\/service\/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00f/);
});

test('AWS docs example: IAM ListUsers with a signed content-type header', async () => {
  const r = await signRequest({
    method: 'GET', url: 'https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08',
    headers: { 'content-type': 'application/x-www-form-urlencoded; charset=utf-8' }, signHeaders: ['content-type'],
    accessKeyId: EXAMPLE_ID, secretAccessKey: EXAMPLE_KEY, region: 'us-east-1', service: 'iam', includeContentSha256: false,
    now: new Date('2015-08-30T12:36:00Z'),
  });
  assert.equal(r.signature, '5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7');
});

test('lambda request: content sha header present, signed, and unsigned payload allowed', async () => {
  const r = await signRequest({
    method: 'GET', url: 'https://x.lambda-web.us-east-1.on.aws/ping?b=2&a=1', accessKeyId: EXAMPLE_ID, secretAccessKey: EXAMPLE_KEY,
    region: 'us-east-1', service: 'lambda', payloadHash: 'UNSIGNED-PAYLOAD', now: new Date('2026-10-18T00:00:00Z'),
  });
  assert.equal(r.headers['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD');
  assert.match(r.headers.authorization, /SignedHeaders=host;x-amz-content-sha256;x-amz-date,/);
  assert.match(r.canonicalRequest, /\n\/ping\na=1&b=2\n/);
});

test('missing signHeaders entry is an error, not a silent skip', async () => {
  await assert.rejects(signRequest({
    method: 'GET', url: 'https://h/', signHeaders: ['x-nope'], accessKeyId: 'a', secretAccessKey: 'b', region: 'r', service: 's',
  }), /not given/);
});

test("query: '+' is a literal plus, a space is %20, and the returned url is exactly what was signed", async () => {
  const r = await signRequest({
    method: 'GET', url: 'https://h.example/p?q=a+b&s=c%20d&z', accessKeyId: EXAMPLE_ID, secretAccessKey: EXAMPLE_KEY,
    region: 'us-east-1', service: 'lambda', now: new Date('2026-10-18T00:00:00Z'),
  });
  assert.match(r.canonicalRequest, /\nq=a%2Bb&s=c%20d&z=\n/);
  assert.equal(r.url, 'https://h.example/p?q=a%2Bb&s=c%20d&z=');
  const plain = await signRequest({ method: 'GET', url: 'https://h.example/p', accessKeyId: 'a', secretAccessKey: 'b', region: 'r', service: 's' });
  assert.equal(plain.url, 'https://h.example/p');
});
