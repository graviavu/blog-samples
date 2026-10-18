// core.mjs - the test application, shared by the Web Function (Node http server) and the Event Function (Function URL).
// It never returns the value of any header, only whether it is present and its SHA-256, so the logs and the results
// files cannot contain a token.
import { createHash, randomUUID } from 'node:crypto';

export const ENV_ID = randomUUID().slice(0, 8); // one per execution environment (module / process lifetime)
let counter = 0;
let inflight = 0;
let maxInflight = 0;

const sha = (v) => createHash('sha256').update(v).digest('hex');
const hdr = (headers, name) => {
  const v = headers[name];
  return v === undefined ? undefined : Array.isArray(v) ? v.join(',') : String(v);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The distribution has /wf/* and /fu/* behaviors and CloudFront forwards the full path; the Worker strips its prefix.
export function normalisePath(p) {
  return p.replace(/^\/(wf|fu)(?=\/|$)/, '') || '/';
}

function headerInfo(headers, name) {
  const v = hdr(headers, name);
  return v === undefined ? { present: false } : { present: true, sha256: sha(v), length: v.length };
}

/**
 * @param {{kind:string, method:string, path:string, query:URLSearchParams, headers:Record<string,string|string[]>}} req
 *   headers must have lower-case names
 * @param {{start(status:number, headers:Record<string,string>):void, write(chunk:string):void, end():void}} out
 */
export async function route(req, out) {
  const path = normalisePath(req.path);
  const base = { 'content-type': 'application/json', 'x-lwf-kind': req.kind, 'x-lwf-env': ENV_ID };
  const json = (status, obj, extra = {}) => {
    out.start(status, { ...base, ...extra });
    out.write(JSON.stringify(obj));
    out.end();
  };
  const n = ++counter;
  inflight++;
  if (inflight > maxInflight) maxInflight = inflight;
  try {
    if (req.method !== 'GET' && req.method !== 'HEAD' && req.method !== 'OPTIONS') return json(405, { error: 'method not allowed' });
    if (path === '/ping') {
      return json(200, { kind: req.kind, env: ENV_ID, n, host: hdr(req.headers, 'host') || null, t: Date.now() });
    }
    if (path === '/headers') {
      // What did the app receive? Presence and hash only. 'host' is the one value that is safe to return.
      return json(200, {
        kind: req.kind, env: ENV_ID,
        host: hdr(req.headers, 'host') || null,
        authorization: headerInfo(req.headers, 'authorization'),
        'x-app-auth': headerInfo(req.headers, 'x-app-auth'),
        'x-amz-cf-id': { present: hdr(req.headers, 'x-amz-cf-id') !== undefined },
        via: hdr(req.headers, 'via') || null,
      });
    }
    if (path === '/slow') {
      const ms = Math.min(Math.max(parseInt(req.query.get('ms') || '2000', 10) || 0, 0), 10000);
      await sleep(ms);
      return json(200, { kind: req.kind, env: ENV_ID, n, slept: ms, inflight, maxInflight, t: Date.now() });
    }
    if (path === '/stream') {
      const chunks = Math.min(parseInt(req.query.get('chunks') || '10', 10) || 10, 30);
      const gap = Math.min(parseInt(req.query.get('gap') || '300', 10) || 300, 2000);
      out.start(200, { ...base, 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      const t0 = Date.now();
      for (let i = 0; i < chunks; i++) {
        out.write(`chunk ${i} +${Date.now() - t0}ms\n`);
        if (i < chunks - 1) await sleep(gap);
      }
      return out.end();
    }
    if (path === '/cache') {
      return json(200, { kind: req.kind, env: ENV_ID, n, nonce: randomUUID().slice(0, 8), t: Date.now() },
        { 'cache-control': 'public, max-age=60' });
    }
    return json(404, { error: 'not found', path });
  } finally {
    inflight--;
  }
}
