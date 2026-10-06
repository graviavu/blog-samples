import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);

export function readSource(name) {
  return readFileSync(join(root, 'function', name), 'utf8');
}

// A Date whose no-argument constructor returns a fixed time (CloudFront Functions return the start time of the run).
export function fakeDate(ms) {
  return class extends Date {
    constructor(...a) { if (a.length === 0) super(ms); else super(...a); }
    static now() { return ms; }
  };
}

export const T = (iso) => Date.parse(iso);

// Loads function/slot.js or slot-legacy.js with a stub for the 'cloudfront' module and a fixed clock.
// The files are ES modules for the CloudFront runtime; here the import line is swapped for the stub and the rest
// is evaluated unchanged. store: key -> raw string value (as KeyValueStore returns before JSON parsing).
export function loadSlot({ file = 'slot.js', store = {}, carrier = 'query', now, getThrows = false } = {}) {
  let src = readSource(file);
  if (!src.includes("import cf from 'cloudfront';")) throw new Error('import line not found');
  src = src.replace("import cf from 'cloudfront';", 'const cf = __cf;');
  if (!src.includes("const CARRIER = 'query';")) throw new Error('CARRIER line not found');
  src = src.replace("const CARRIER = 'query';", `const CARRIER = '${carrier}';`);
  const reads = [];
  const stub = {
    kvs: () => ({
      get: async (k, opts) => {
        reads.push([k, opts]);
        if (getThrows) throw new Error('store unavailable');
        if (!Object.prototype.hasOwnProperty.call(store, k)) throw new Error('key not found');
        const v = store[k];
        return opts && opts.format === 'json' ? JSON.parse(v) : v;
      },
    }),
  };
  const handler = new Function('__cf', 'Date', `${src}\nreturn handler;`)(stub, fakeDate(now));
  return { handler, reads };
}

export const win = (o) => JSON.stringify(o);

export function viewerEvent({ query = {}, headers = {} } = {}) {
  return { request: { method: 'GET', uri: '/x/none', querystring: query, headers: { host: { value: 'dexample.cloudfront.net' }, ...headers }, cookies: {} } };
}

// Loads function/origin.js (CommonJS, the Lambda handler).
export function loadOrigin() {
  const m = { exports: {} };
  new Function('require', 'module', 'exports', readSource('origin.js'))(require, m, m.exports);
  return m.exports.handler;
}

export const urlEvent = (path, { query, headers = {} } = {}) => ({
  rawPath: path,
  headers,
  queryStringParameters: query,
  requestContext: { http: { method: 'GET' } },
});

// Loads function/edge-origin-response.js with its constants replaced.
export function loadEdge({ start = 0, end = 1440, inTtl = 15, outTtl = 45, rewriteErrors = false, now }) {
  let src = readSource('edge-origin-response.js');
  const set = (name, val) => {
    const re = new RegExp(`const ${name} = [^;]*;`);
    if (!re.test(src)) throw new Error(`constant ${name} not found`);
    src = src.replace(re, `const ${name} = ${val};`);
  };
  set('WINDOW_START_MIN', start); set('WINDOW_END_MIN', end); set('IN_TTL', inTtl); set('OUT_TTL', outTtl);
  set('REWRITE_ERRORS', rewriteErrors);
  const m = { exports: {} };
  new Function('module', 'exports', 'Date', src)(m, m.exports, fakeDate(now));
  return m.exports.handler;
}

export const edgeEvent = (status, headers = {}) => ({ Records: [{ cf: { response: { status: String(status), statusDescription: 'x', headers } } }] });

// Reads the TTLs of the test cache policies from template.yaml: { orig: [min, default, max], ... }
export function readPolicies(templateFile = 'template.yaml') {
  const text = readFileSync(join(root, templateFile), 'utf8');
  const out = {};
  const re = /^ {2}Ttl(\w+)Policy:\n[\s\S]*?MinTTL: (\d+)\n\s+DefaultTTL: (\d+)\n\s+MaxTTL: (\d+)\n/gm;
  let m;
  while ((m = re.exec(text))) out[m[1].toLowerCase()] = [Number(m[2]), Number(m[3]), Number(m[4])];
  return out;
}
