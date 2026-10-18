// worker.mjs - Cloudflare Worker for the Lambda Web Functions sample. ES module, no dependency (SigV4 is ./sigv4.mjs).
//
//   /wf/*          signed (SigV4, service "lambda") request to the Web Function endpoint        (T2: Worker as proxy)
//   /fu/*          signed request to the Function URL
//   /cf/*          unsigned request to the CloudFront distribution (Cloudflare in front of CloudFront, via a Worker)
//   /cache/wf/*    like /wf/* but through the Worker cache (Cache API), keyed by URL
//   /cache/fu/*    like /fu/*
//   /edge/*        answered by the Worker itself (the "Workers baseline": ping, stream)
//   /health        "ok"
//
// Bindings (set by lwf-sample.sh): plain text WF_HOST, FU_HOST, CF_ORIGIN, AWS_REGION; secrets AWS_ACCESS_KEY_ID and
// AWS_SECRET_ACCESS_KEY (an IAM user that may only invoke the two sample endpoints). The Worker never logs a header value.
import { signRequest } from './sigv4.mjs';

const DROP = /^(host|authorization|connection|content-length|cf-|x-forwarded-|x-real-ip|true-client-ip|cdn-loop|x-amz-)/i;

function forwardHeaders(req) {
  const h = {};
  for (const [k, v] of req.headers) if (!DROP.test(k)) h[k.toLowerCase()] = v;
  return h;
}

async function signedFetch(req, env, host, rest, search) {
  if (!env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY) return new Response('worker has no AWS key', { status: 500 });
  const url = `https://${host}${rest}${search}`;
  // Lambda removes a SigV4 Authorization header before the app sees it, so the viewer's Authorization is NOT forwarded
  // (it could not arrive anyway); an application token has to travel in x-app-auth.
  const { headers } = await signRequest({
    method: req.method, url, headers: forwardHeaders(req),
    accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
    region: env.AWS_REGION || 'us-east-1', service: 'lambda', payloadHash: 'UNSIGNED-PAYLOAD',
  });
  const t0 = Date.now();
  const upstream = await fetch(url, { method: req.method, headers });
  return withTiming(upstream, 'worker-subrequest', Date.now() - t0, 'worker-signed');
}

function withTiming(upstream, name, ms, via) {
  const r = new Response(upstream.body, upstream);
  r.headers.append('server-timing', `${name};dur=${ms}`);
  r.headers.set('x-lwf-via', via);
  return r;
}

async function plainFetch(req, env, rest, search) {
  const url = `https://${env.CF_ORIGIN}${rest}${search}`;
  const t0 = Date.now();
  const upstream = await fetch(url, { method: req.method, headers: forwardHeaders(req) });
  return withTiming(upstream, 'worker-subrequest', Date.now() - t0, 'worker-to-cloudfront');
}

function edgeResponse(rest, url) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  if (rest === '/ping') return Response.json({ kind: 'worker', t: Date.now() }, { headers: { 'x-lwf-via': 'worker-edge' } });
  if (rest === '/stream') {
    const chunks = Math.min(parseInt(url.searchParams.get('chunks') || '10', 10) || 10, 30);
    const gap = Math.min(parseInt(url.searchParams.get('gap') || '300', 10) || 300, 2000);
    const { readable, writable } = new TransformStream();
    const w = writable.getWriter();
    const te = new TextEncoder();
    const t0 = Date.now();
    (async () => {
      for (let i = 0; i < chunks; i++) {
        await w.write(te.encode(`chunk ${i} +${Date.now() - t0}ms\n`));
        if (i < chunks - 1) await sleep(gap);
      }
      await w.close();
    })();
    return new Response(readable, { headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'x-lwf-via': 'worker-edge' } });
  }
  return new Response('not found', { status: 404 });
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('method not allowed', { status: 405 });
    if (p === '/health') return new Response('ok');
    let m;
    if ((m = p.match(/^\/wf(\/.*|)$/))) return signedFetch(req, env, env.WF_HOST, m[1] || '/', url.search);
    if ((m = p.match(/^\/fu(\/.*|)$/))) return signedFetch(req, env, env.FU_HOST, m[1] || '/', url.search);
    if ((m = p.match(/^\/cf(\/.*)$/))) return plainFetch(req, env, m[1], url.search);
    if ((m = p.match(/^\/edge(\/.*)$/))) return edgeResponse(m[1], url);
    if ((m = p.match(/^\/cache\/(wf|fu)(\/.*|)$/))) {
      const cache = caches.default;
      const key = new Request(url.toString(), { method: 'GET' });
      const hit = await cache.match(key);
      if (hit) {
        const r = new Response(hit.body, hit);
        r.headers.set('x-lwf-cache', 'HIT');
        return r;
      }
      const host = m[1] === 'wf' ? env.WF_HOST : env.FU_HOST;
      const resp = await signedFetch(req, env, host, m[2] || '/', url.search);
      if (resp.status === 200 && /max-age=\d+/.test(resp.headers.get('cache-control') || '')) {
        ctx.waitUntil(cache.put(key, resp.clone()));
      }
      const r = new Response(resp.body, resp);
      r.headers.set('x-lwf-cache', 'MISS');
      return r;
    }
    return new Response('not found', { status: 404 });
  },
};
