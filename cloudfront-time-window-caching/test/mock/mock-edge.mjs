// Local mock of the deployed stack, used ONLY to test verify.sh without AWS. It is NOT a CloudFront emulator.
// It runs the real function/slot.js, slot-legacy.js, origin.js and edge-origin-response.js, takes the cache policy
// TTLs from template.yaml, and implements a simple cache that follows the rules the POST states (plus the stated
// hypotheses for the undocumented cases), so a PASS here says the script's logic and parsing work, nothing about
// real CloudFront. KeyValueStore propagation is a fixed delay. Time can run faster than real time (MOCK_SPEED).
//
// Usage: node test/mock/mock-edge.mjs <port> <edgePort> <kvsWriteLog> <directPort>
// Env:   CARRIER (query|header)  MOCK_SPEED (virtual seconds per real second, default 1)  MOCK_CLOCK_ANCHOR (epoch s)
//        PROPAGATION_MS (real ms, default 1500)  EDGE_WINDOW_START_MIN EDGE_WINDOW_END_MIN EDGE_IN_TTL EDGE_OUT_TTL
//        EDGE_REWRITE_ERRORS (true|false)  MOCK_DIRECT_OPEN=1 (direct calls to the origin succeed: tests the FAIL path)
//        MOCK_BREAK=no-collapse,ignore-min  (comma list) deliberately breaks the mock to prove verify.sh reports FAIL
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { loadSlot, loadOrigin, loadEdge, readPolicies, urlEvent } from '../helpers.mjs';

const [port, edgePort, writeLog, directPort] = [Number(process.argv[2]), Number(process.argv[3]), process.argv[4], Number(process.argv[5] || 18789)];
const CARRIER = process.env.CARRIER || 'query';
const SPEED = Number(process.env.MOCK_SPEED || 1);
const ANCHOR = Number(process.env.MOCK_CLOCK_ANCHOR || Math.floor(Date.now() / 1000)) * 1000;
const DELAY = Number(process.env.PROPAGATION_MS || 1500);
const vnow = () => ANCHOR + (Date.now() - ANCHOR) * SPEED;
const edgeOpts = {
  start: Number(process.env.EDGE_WINDOW_START_MIN || 0), end: Number(process.env.EDGE_WINDOW_END_MIN || 1440),
  inTtl: Number(process.env.EDGE_IN_TTL || 15), outTtl: Number(process.env.EDGE_OUT_TTL || 45),
  rewriteErrors: process.env.EDGE_REWRITE_ERRORS === 'true',
};

const BREAK = (process.env.MOCK_BREAK || '').split(',');
const POL = readPolicies();
POL.win = [600, 600, 3600];
POL.d0 = [0, 0, 3600];
POL.d60 = [0, 60, 3600];
const MAIN_BEHAVIORS = { 'p-orig': 'orig', 'p-b': 'b', 'p-m0': 'm0', 'p-defhi': 'defhi', legacy: 'win' };
const EDGE_BEHAVIORS = { d0: 'd0', d60: 'd60' };

const origin = loadOrigin();
const SEED = { window: '{"startMin":810,"endMin":1200,"slotSeconds":5,"rev":1}' };

function store() {
  const s = { ...SEED };
  if (writeLog && existsSync(writeLog)) {
    for (const line of readFileSync(writeLog, 'utf8').split('\n').filter(Boolean)) {
      const [ms, op, key, ...rest] = line.split(' ');
      if (Date.now() >= Number(ms) + DELAY) { if (op === 'put') s[key] = rest.join(' '); else delete s[key]; }
    }
  }
  return s;
}

function parseCc(h) {
  const v = (h && h['cache-control']) || '';
  const out = { flags: new Set(), maxAge: undefined, sMaxAge: undefined, present: v !== '' };
  for (const part of String(v).split(',').map((x) => x.trim().toLowerCase()).filter(Boolean)) {
    const [k, val] = part.split('=');
    if (k === 'max-age') out.maxAge = Number(val);
    else if (k === 's-maxage') out.sMaxAge = Number(val);
    else out.flags.add(k);
  }
  return out;
}

// Edge TTL in seconds under the rules of the post (documented cases) and the hypotheses H1 (undocumented cases).
function edgeTtl(status, h, [min, def, max]) {
  const cc = parseCc(h);
  const life = cc.sMaxAge !== undefined ? cc.sMaxAge : cc.maxAge;
  if (status >= 400) {
    // docs: error caching minimum TTL 10 s; 404 and 5xx cached anyway, 400 and 403 only when the header is present
    if (life !== undefined) return Math.max(10, life);
    return [404, 414, 500, 501, 502, 503, 504].includes(status) ? 10 : 0;
  }
  if (cc.flags.has('no-store') || cc.flags.has('no-cache') || cc.flags.has('private')) return min > 0 ? min : 0;
  let t = life;
  if (t === undefined) {
    const exp = h && h.expires ? Date.parse(h.expires) : NaN;
    t = Number.isNaN(exp) ? def : Math.max(0, Math.floor((exp - vnow()) / 1000));
  }
  return Math.min(BREAK.includes('ignore-min') ? t : Math.max(t, min), max);
}

const caches = new Map();   // per server
const inflight = new Map();

async function handle(req, res, edge) {
  const url = new URL(req.url, 'http://x');
  const seg = url.pathname.split('/')[1];
  const behaviors = edge ? EDGE_BEHAVIORS : MAIN_BEHAVIORS;
  const polName = behaviors[seg] || (edge ? 'd0' : 'win');
  const policy = POL[polName];
  const route = url.pathname.split('/').pop();
  const cache = caches.get(edge ? 'e' : 'm') || caches.set(edge ? 'e' : 'm', new Map()).get(edge ? 'e' : 'm');

  // viewer request function (main stack only: the default behavior and /legacy/)
  let slot = null;
  let fwdQuery;
  let fwdHeaders = {};
  if (!edge && polName === 'win') {
    const ev = { request: { method: 'GET', uri: url.pathname, querystring: {}, headers: {}, cookies: {} } };
    for (const [k, v] of url.searchParams) ev.request.querystring[k] = ev.request.querystring[k] ? { value: ev.request.querystring[k].value, multiValue: [...(ev.request.querystring[k].multiValue || [{ value: ev.request.querystring[k].value }]), { value: v }] } : { value: v };
    for (const [k, v] of Object.entries(req.headers)) ev.request.headers[k] = { value: v };
    const { handler } = loadSlot({ file: seg === 'legacy' ? 'slot-legacy.js' : 'slot.js', store: store(), carrier: CARRIER, now: vnow() });
    const out = await handler(ev);
    slot = CARRIER === 'header' ? out.headers['x-cache-slot'].value : out.querystring.slot.value;
    if (CARRIER === 'header') fwdHeaders = { 'x-cache-slot': slot }; else fwdQuery = { slot };
  }

  const key = url.pathname + '|' + (slot || '');
  const now = vnow();
  const hit = cache.get(key);
  let xc = 'Miss from cloudfront';
  let entry = hit;
  if (hit && hit.expires > now) {
    xc = 'Hit from cloudfront';
  } else {
    const fetchOrigin = async (conditional) => {
      const headers = { ...fwdHeaders };
      if (conditional) headers['if-none-match'] = conditional;
      const r = await origin(urlEvent(url.pathname, { query: fwdQuery, headers }));
      let rh = {};
      for (const [k, v] of Object.entries(r.headers || {})) rh[k.toLowerCase()] = v;
      if (edge) { // Lambda@Edge origin-response
        const cfh = {};
        for (const [k, v] of Object.entries(rh)) cfh[k] = [{ key: k, value: v }];
        const resp = await loadEdge({ ...edgeOpts, now: vnow() })({ Records: [{ cf: { response: { status: String(r.statusCode), headers: cfh } } }] });
        rh = {};
        for (const [k, v] of Object.entries(resp.headers)) rh[k] = v[0].value;
      }
      return { status: r.statusCode, headers: rh, body: r.body || '' };
    };
    const collapse = !BREAK.includes('no-collapse') && (policy[0] > 0 || route !== 'slow');   // docs: min 0 plus no-store (route slow) prevents collapsing
    if (hit && hit.etag) {
      const r = await fetchWithCollapse(key, collapse, () => fetchOrigin(hit.etag));
      if (r.status === 304) {
        entry = { ...hit, created: vnow(), expires: vnow() + edgeTtl(200, hit.headers, policy) * 1000 };
        cache.set(key, entry);
        xc = 'RefreshHit from cloudfront';
      } else { entry = null; }
    } else { entry = null; }
    if (!entry) {
      const r = await fetchWithCollapse(key, collapse, () => fetchOrigin());
      const ttl = edgeTtl(r.status, r.headers, policy);
      entry = { status: r.status, headers: r.headers, body: r.body, etag: r.headers.etag, created: vnow(), expires: vnow() + ttl * 1000 };
      if (ttl > 0) cache.set(key, entry); else cache.delete(key);
    }
  }
  const age = Math.floor((vnow() - entry.created) / 1000);
  const out = { 'content-type': 'application/json', 'x-cache': xc, 'x-amz-cf-pop': 'MOCK1-C1' };
  if (xc !== 'Miss from cloudfront') out.age = String(age);
  res.writeHead(entry.status, out);
  res.end(entry.body);
}

function fetchWithCollapse(key, collapse, fn) {
  if (!collapse) return fn();
  if (inflight.has(key)) return inflight.get(key);
  const p = fn().finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

const wrap = (edge) => (req, res) => handle(req, res, edge).catch((e) => { res.writeHead(502); res.end(String(e && e.message)); });
http.createServer(wrap(false)).listen(port, '127.0.0.1');
http.createServer(wrap(true)).listen(edgePort, '127.0.0.1');

// Direct calls to the origin function URL (no CloudFront signing): refused unless MOCK_DIRECT_OPEN=1 (to test the FAIL path).
http.createServer((req, res) => {
  res.writeHead(process.env.MOCK_DIRECT_OPEN === '1' ? 200 : 403);
  res.end('{"message":"Forbidden"}');
}).listen(directPort, '127.0.0.1');
