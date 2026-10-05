// Local mock of the deployed stack, used ONLY to test verify.sh without AWS. It is not a CloudFront emulator:
// it runs the real function/route.js and function/edge-origin-request.js against an in-memory route table,
// a simple 60 s cache, and echo origins, and models KeyValueStore propagation with a fixed delay.
// Usage: node test/mock/mock-edge.mjs <port> <edgePort> <kvsWriteLog>   env: CACHE_KEY_ATTRIBUTE (x-backend|none), PROPAGATION_MS
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { loadRoute, readSource } from '../helpers.mjs';

const [port, edgePort, writeLog] = [Number(process.argv[2]), Number(process.argv[3]), process.argv[4]];
const CACHE_KEY = process.env.CACHE_KEY_ATTRIBUTE || 'x-backend';
const DELAY = Number(process.env.PROPAGATION_MS || 3000);
const SEED = {
  'route-a': 'origin-a.example.net', 'route-b': 'origin-b.example.net', 'bad-colon': 'example.net:8443',
  'bad-ip': '192.0.2.10', 'bad-upper': 'Origin-A.example.net',
};
const cache = new Map();
let n = 0;

function store() {
  const s = { ...SEED };
  if (writeLog && existsSync(writeLog)) {
    for (const line of readFileSync(writeLog, 'utf8').split('\n').filter(Boolean)) {
      const [ms, op, key, value] = line.split(' ');
      if (Date.now() >= Number(ms) + DELAY) { if (op === 'put') s[key] = value; else delete s[key]; }
    }
  }
  return s;
}

function echo(name, headers, url, hostSeen) {
  return {
    status: 200,
    headers: { 'content-type': 'application/json', 'x-origin-name': name },
    body: JSON.stringify({
      origin: name, host: hostSeen, path: url.pathname, query: url.search.slice(1), xBackend: headers['x-backend'],
      xTestMarker: headers['x-test-marker'], xOriginMarker: 'from-default-origin', requestId: `req-${++n}`, nowEpoch: Math.floor(Date.now() / 1000),
    }),
  };
}

function cfHeaders(headers) { // shape of a CloudFront Function event
  const h = {};
  for (const [k, v] of Object.entries(headers)) h[k] = { value: v };
  return h;
}

function viewerRequest(req, url) {
  const path = url.pathname;
  if (path.startsWith('/probe/')) {
    return { status: 200, headers: { 'x-seen-host': req.headers.host, 'cache-control': 'no-store' }, body: '' };
  }
  const { handler, calls } = loadRoute({ store: store() });
  return handler({ request: { method: 'GET', uri: path, headers: cfHeaders(req.headers) } }).then((res) => {
    if (res.statusCode) return { status: res.statusCode, headers: {}, body: '' };
    const o = calls.updates[0].domainName;
    return echo(o.split('.')[0], req.headers, url, calls.updates[0].hostHeader);
  });
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const control = url.pathname.startsWith('/control/');
  const keyed = !control && CACHE_KEY !== 'none' && !url.pathname.startsWith('/probe/');
  const ck = url.pathname + (keyed ? `|${req.headers['x-backend'] || ''}` : '');
  const hit = cache.get(ck);
  let out;
  let xc = 'Miss from cloudfront';
  if (hit && hit.exp > Date.now()) { out = hit.out; xc = 'Hit from cloudfront'; }
  else {
    out = await viewerRequest(req, url);
    if (out.status === 200 && !url.pathname.startsWith('/probe/')) cache.set(ck, { out, exp: Date.now() + 60000 });
  }
  res.writeHead(out.status, { ...out.headers, 'x-cache': xc, 'x-amz-cf-pop': 'MOCK1-C1' });
  res.end(out.body);
}).listen(port, '127.0.0.1');

// Mock of the Lambda@Edge variant on a second port.
const edgeSrc = readSource('edge-origin-request.js');
http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const m = { exports: {} };
  new Function('module', 'exports', edgeSrc)(m, m.exports);
  const request = { uri: url.pathname, headers: {}, origin: { custom: { domainName: 'origin-default.example.net' } } };
  for (const [k, v] of Object.entries(req.headers)) request.headers[k] = [{ key: k, value: v }];
  m.exports.handler({ Records: [{ cf: { request } }] }, {}, (e, out) => {
    if (out.status) { res.writeHead(Number(out.status)); res.end(); return; }
    const o = echo(out.origin.custom.domainName.split('.')[0], req.headers, url, out.headers.host[0].value);
    res.writeHead(200, { ...o.headers, 'x-cache': 'Miss from cloudfront' });
    res.end(o.body);
  });
}).listen(edgePort, '127.0.0.1');
