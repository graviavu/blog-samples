// A tiny CloudFront simulation for the stub tests: runs the REAL function code from the template (so a mutated template changes the
// behaviour), a cache keyed by path + the x-cache-bust header, an S3 origin that reads $STUB_DIR/s3, and a propagation delay.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { templateCode, render, load } from '../lib/render.mjs';

const S = process.env.STUB_DIR;
const [url, out, dump, ...hdrs] = process.argv.slice(2);
const now = Number(process.env.STUB_NOW);
const rd = (f, d) => (existsSync(join(S, f)) ? readFileSync(join(S, f), 'utf8') : d);
const params = (f) => { const o = {}; for (const p of JSON.parse(rd(f, '[]'))) o[p.ParameterKey] = p.ParameterValue; return o; };
const delay = Number(process.env.STUB_PROP_DELAY ?? 20);
const slept = Number(rd('slept', '0'));
const changedAt = Number(rd('params.t', '0'));
const effective = slept - changedAt >= delay ? params('params.json') : params('params.prev.json');

const root = process.env.STUB_TEMPLATE_ROOT || join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const code = render(templateCode(root), effective);
const headers = {};
for (const h of hdrs) { const i = h.indexOf(':'); headers[h.slice(0, i).trim().toLowerCase()] = { value: h.slice(i + 1).trim() }; }
const path = new URL(url).pathname;
const req = load(code, now * 1000).handler({ request: { method: 'GET', uri: path, headers } });
const bust = req.headers['x-cache-bust'] ? req.headers['x-cache-bust'].value : '';
const key = path + '|' + bust;

const cache = JSON.parse(rd('cache.json', '{}'));
const ttl = Number(effective.LongTtl || 86400);
let status = 200, body = '', xcache = 'Miss from cloudfront', age = null;
const hit = cache[key];
if (hit && now - hit.at < ttl) {
  body = hit.body; xcache = 'Hit from cloudfront'; age = now - hit.at;
} else {
  const f = join(S, 's3', path.slice(1));
  const rejectHeader = process.env.STUB_S3_REJECT === '1' && bust !== '';
  if (!existsSync(f) || rejectHeader || process.env.STUB_S3_ALWAYS403 === '1') { status = 403; body = '<Error><Code>AccessDenied</Code></Error>'; xcache = 'Error from cloudfront'; }
  else { body = readFileSync(f, 'utf8'); cache[key] = { body, at: now }; writeFileSync(join(S, 'cache.json'), JSON.stringify(cache)); }
}
if (out) writeFileSync(out, body);
if (dump) writeFileSync(dump, `HTTP/2 ${status}\r\ncontent-type: text/plain\r\nx-cache: ${xcache}\r\n${age !== null ? `age: ${age}\r\n` : ''}via: 1.1 abcdef.cloudfront.net (CloudFront)\r\n\r\n`);
