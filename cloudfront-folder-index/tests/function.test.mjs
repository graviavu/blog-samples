// Runs the CloudFront Function code that is inlined in cfn/stack.yaml against sample events. No dependencies.
// The template carries the code as an inline block under FunctionCode; this reads it from there, so the test and the stack cannot drift apart.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const lines = readFileSync(join(here, '..', 'cfn', 'stack.yaml'), 'utf8').split('\n');
const start = lines.findIndex((l) => l.includes('FunctionCode: !Sub')) + 2; // after "- |"
const end = lines.findIndex((l, i) => i > start && l.trim().startsWith('- Old:'));
assert.ok(start > 1 && end > start, 'function code block not found in the template');
const code = lines.slice(start, end).map((l) => l.slice(10)).join('\n')
  .replace('${Old}', '').replace('${DomainName}', 'www.example.invalid');

function load(oldHost) {
  const src = oldHost ? code.replace("var oldHost = '';", `var oldHost = '${oldHost}';`) : code;
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx.handler;
}
const ev = (uri, host = 'dabc.cloudfront.net', querystring = {}) => ({ request: { uri, headers: { host: { value: host } }, querystring } });

test('folder URL gets index.html appended', () => {
  const r = load()(ev('/posts/x/'));
  assert.equal(r.uri, '/posts/x/index.html');
});
test('root URL gets index.html', () => {
  assert.equal(load()(ev('/')).uri, '/index.html');
});
test('file URL passes through unchanged', () => {
  assert.equal(load()(ev('/posts/x/index.html')).uri, '/posts/x/index.html');
  assert.equal(load()(ev('/404.html')).uri, '/404.html');
});
test('no slash and no extension redirects to the slash form with 301', () => {
  const r = load()(ev('/posts/x'));
  assert.equal(r.statusCode, 301);
  assert.equal(r.headers.location.value, 'https://www.example.invalid/posts/x/');
});
test('no slash redirect keeps the query string', () => {
  const r = load()(ev('/posts/x', 'h', { a: { value: '1' }, b: { value: '' } }));
  assert.equal(r.headers.location.value, 'https://www.example.invalid/posts/x/?a=1&b');
});
test('old host redirects to the new host in one hop (not used by this sample, kept as in the post)', () => {
  const h = load('old.example.com');
  const r = h(ev('/posts/x', 'old.example.com'));
  assert.equal(r.statusCode, 301);
  assert.equal(r.headers.location.value, 'https://www.example.invalid/posts/x/');
});
