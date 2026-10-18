#!/usr/bin/env node
// probe.mjs - HTTP measurement helper for lwf-sample.sh. Prints ONE JSON object on stdout. No dependency (Node 20+).
//
//   probe.mjs get      URL [--sign] [--header 'name: value']...        one request: status, selected headers, body (max 4 KB), timings
//   probe.mjs latency  URL [--sign] [--n 30] [--warm 3] [--header ..]  sequential GETs on a kept-alive connection: ttfb p50/p90
//   probe.mjs parallel URL [--sign] [--n 64]                           N concurrent GETs: status counts, distinct environments, wall time
//   probe.mjs stream   URL [--sign] [--header ..]                      first byte and arrival time of each chunk
// --worker: add the header x-lwf-token with the value of the environment variable LWF_TOKEN (the Worker's per-run token).
//
// --sign: SigV4 (service lambda, region --region, default us-east-1) with the key read from STDIN as {"id":"..","secret":".."},
// so the secret is never in argv or the environment. Request header VALUES are never printed (only response headers listed below).
import https from 'node:https';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { signRequest } from '../worker/sigv4.mjs';

const KEEP = ['x-cache', 'cf-cache-status', 'x-amz-cf-pop', 'cf-ray', 'age', 'server-timing', 'lambda-web-logstream', 'x-lwf-env', 'x-lwf-via',
  'x-lwf-cache', 'x-lwf-kind', 'cache-control', 'via', 'content-type', 'server', 'x-amzn-errortype'];

function parseArgs(argv) {
  const a = { _: [], header: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === '--sign') a.sign = true;
    else if (t === '--worker') a.worker = true;
    else if (t === '--header') a.header.push(argv[++i]);
    else if (t.startsWith('--')) a[t.slice(2)] = argv[++i];
    else a._.push(t);
  }
  return a;
}

let creds = null;
function loadCreds() {
  if (creds) return creds;
  try { creds = JSON.parse(readFileSync(0, 'utf8')); } catch { creds = null; }
  if (!creds || !creds.id || !creds.secret) { console.log(JSON.stringify({ error: 'no key on stdin (expected {"id":..,"secret":..})' })); process.exit(2); }
  return creds;
}

async function buildHeaders(url, opts) {
  const h = {};
  for (const line of opts.header) { const i = line.indexOf(':'); if (i > 0) h[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim(); }
  if (opts.worker && process.env.LWF_TOKEN) h['x-lwf-token'] = process.env.LWF_TOKEN; // per-run Worker token, from the environment, never argv
  if (!opts.sign) return h;
  const c = loadCreds();
  const s = await signRequest({
    method: 'GET', url, headers: h, accessKeyId: c.id, secretAccessKey: c.secret, region: opts.region || 'us-east-1', service: 'lambda',
  });
  return s.headers;
}

const agent = new https.Agent({ keepAlive: true, maxSockets: Infinity });

// One request. onChunk(ms-since-start) for each data event. Resolves with {status, headers, body, ttfb, total, chunks}.
function request(url, headers, { maxBody = 4096, timeout = 60000 } = {}) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const chunks = [];
    let ttfb = null; let body = ''; let status = 0; let hdrs = {};
    const req = https.request(url, { method: 'GET', headers, agent, timeout }, (res) => {
      ttfb = performance.now() - t0; status = res.statusCode;
      for (const k of KEEP) if (res.headers[k] !== undefined) hdrs[k] = String(res.headers[k]);
      res.on('data', (d) => { chunks.push(Math.round(performance.now() - t0)); if (body.length < maxBody) body += d.toString('utf8'); });
      res.on('end', () => resolve({ status, headers: hdrs, body: body.slice(0, maxBody), ttfb, total: performance.now() - t0, chunks }));
      res.on('error', (e) => resolve({ status, headers: hdrs, error: e.code || e.message, ttfb, total: performance.now() - t0, chunks }));
    });
    req.on('timeout', () => req.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', (e) => resolve({ status: 0, headers: hdrs, error: e.code || e.message, ttfb, total: performance.now() - t0, chunks }));
    req.end();
  });
}

const pct = (arr, p) => { if (!arr.length) return null; const s = [...arr].sort((x, y) => x - y); return Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] * 10) / 10; };
const r1 = (x) => (x === null || x === undefined ? null : Math.round(x * 10) / 10);

async function main() {
  const [cmd, url] = process.argv[2] ? [process.argv[2], process.argv[3]] : [];
  const opts = parseArgs(process.argv.slice(4));
  if (!cmd || !url || !/^https:\/\//.test(url)) { console.log(JSON.stringify({ error: 'usage: probe.mjs get|latency|parallel|stream https://URL [options]' })); process.exit(2); }
  if (cmd === 'get') {
    const r = await request(url, await buildHeaders(url, opts));
    console.log(JSON.stringify({ status: r.status, headers: r.headers, body: r.body, error: r.error || null, ttfbMs: r1(r.ttfb), totalMs: r1(r.total) }));
  } else if (cmd === 'latency') {
    const n = parseInt(opts.n || '30', 10); const warm = parseInt(opts.warm || '3', 10);
    const t = []; const status = {}; let first = {}; let errors = 0;
    for (let i = 0; i < warm + n; i++) {
      const r = await request(url, await buildHeaders(url, opts));
      if (i < warm) continue;
      if (r.error || !r.status) { errors++; continue; }
      status[r.status] = (status[r.status] || 0) + 1;
      if (r.status === 200) t.push(r.ttfb);
      if (!Object.keys(first).length) first = r.headers;
    }
    console.log(JSON.stringify({ n, ok: t.length, errors, status, p50: pct(t, 50), p90: pct(t, 90), min: r1(Math.min(...t)), max: r1(Math.max(...t)), firstHeaders: first }));
  } else if (cmd === 'parallel') {
    const n = parseInt(opts.n || '64', 10); const t0 = performance.now();
    const hs = await Promise.all(Array.from({ length: n }, () => buildHeaders(url, opts)));
    const rs = await Promise.all(hs.map((h) => request(url, h, { timeout: 90000 })));
    const status = {}; const envs = new Set(); const streams = new Set(); let errors = 0;
    for (const r of rs) {
      if (r.error) errors++;
      status[r.status] = (status[r.status] || 0) + 1;
      if (r.status === 200) {
        if (r.headers['x-lwf-env']) envs.add(r.headers['x-lwf-env']);
        if (r.headers['lambda-web-logstream']) streams.add(r.headers['lambda-web-logstream']);
      }
    }
    const lat = rs.filter((r) => r.status === 200).map((r) => r.total);
    console.log(JSON.stringify({ n, status, errors, distinctEnvironments: envs.size, distinctLogStreams: streams.size, wallMs: r1(performance.now() - t0), p50: pct(lat, 50), p90: pct(lat, 90) }));
  } else if (cmd === 'stream') {
    const r = await request(url, await buildHeaders(url, opts), { maxBody: 8192 });
    console.log(JSON.stringify({ status: r.status, headers: r.headers, error: r.error || null, firstByteMs: r1(r.ttfb), totalMs: r1(r.total), dataEvents: r.chunks.length, chunkArrivalMs: r.chunks, lines: (r.body.match(/\n/g) || []).length }));
  } else { console.log(JSON.stringify({ error: `unknown command ${cmd}` })); process.exit(2); }
}
main().catch((e) => { console.log(JSON.stringify({ error: String(e && e.message || e) })); process.exit(1); });
