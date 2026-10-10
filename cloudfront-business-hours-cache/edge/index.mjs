// Lambda@Edge origin-response function: no cache in business hours, long cache outside.
//
// Reads {"startMin":780,"endMin":1080,"inTtl":0,"outTtl":14400} from one S3 object, computes the minutes since
// 00:00 UTC and sets   Cache-Control: public, max-age=0, s-maxage=<ttl>
//   startMin <= minutes < endMin  -> inTtl   (0 means CloudFront does not cache the object)
//   otherwise                     -> outTtl
// Rules: only 200, 203, 204 and 206 are rewritten (errors, redirects and 304 are left alone). A response is also left
// untouched when the origin says Cache-Control private, no-store or no-cache, or sets a cookie (set-cookie): the
// origin knows better than a clock, and a shared cache must not keep per-user content.
//  any problem reading or parsing the config gives s-maxage=0, never a long TTL.
//
// Lambda@Edge has no environment variables, so run-test.sh replaces the two __PLACEHOLDERS__ below in the packaged copy.

const CONFIG_BUCKET = '__CONFIG_BUCKET__';
const CONFIG_KEY = '__CONFIG_KEY__';
const CONFIG_CACHE_MS = 30000; // a good config is kept in memory this long
const FAIL_CACHE_MS = 5000;    // a failure is remembered briefly, so an S3 outage does not mean one S3 call per request
const MAX_TTL_SECONDS = 31536000;
const REWRITE_STATUS = new Set([200, 203, 204, 206]);
export const FALLBACK_CACHE_CONTROL = 'public, max-age=0, s-maxage=0';

const isInt = (v, min, max) => Number.isInteger(v) && v >= min && v <= max;

// Returns a clean config object, or null when the config is not usable.
export function parseConfig(text) {
  let c;
  try { c = JSON.parse(text); } catch { return null; }
  if (c === null || typeof c !== 'object') return null;
  const { startMin, endMin, inTtl, outTtl } = c;
  if (!isInt(startMin, 0, 1439) || !isInt(endMin, 1, 1440) || startMin >= endMin) return null; // one window, same UTC day
  if (!isInt(inTtl, 0, MAX_TTL_SECONDS) || !isInt(outTtl, 0, MAX_TTL_SECONDS)) return null;
  return { startMin, endMin, inTtl, outTtl };
}

export function minutesSinceMidnightUtc(date) {
  return date.getUTCHours() * 60 + date.getUTCMinutes();
}

// startMin is inclusive, endMin is exclusive.
export function cacheControlFor(config, date) {
  const m = minutesSinceMidnightUtc(date);
  const ttl = m >= config.startMin && m < config.endMin ? config.inTtl : config.outTtl;
  return `public, max-age=0, s-maxage=${ttl}`;
}

// True when the origin asked for no shared caching (private, no-store, no-cache) or sets a cookie.
export function originForbidsShared(headers) {
  const h = headers || {};
  if (Array.isArray(h['set-cookie']) && h['set-cookie'].length > 0) return true;
  const cc = (Array.isArray(h['cache-control']) ? h['cache-control'] : []).map((x) => x && x.value).join(',');
  return /(^|[\s,])(private|no-store|no-cache)(?=$|[\s,=])/i.test(cc);
}

// loadText: async () => string with the config JSON (throws on failure). now: () => Date. Both are injectable for tests.
export function makeHandler({ loadText, now = () => new Date(), cacheMs = CONFIG_CACHE_MS, failMs = FAIL_CACHE_MS }) {
  let cached = null;   // { config|null, until }
  let inflight = null;

  async function getConfig() {
    const t = now().getTime();
    if (cached && t < cached.until) return cached.config;
    if (!inflight) {
      inflight = (async () => {
        try {
          const config = parseConfig(await loadText());
          if (!config) console.log('config invalid, using fallback');
          cached = { config, until: now().getTime() + (config ? cacheMs : failMs) };
        } catch (e) {
          console.log(`config read failed (${e && e.name ? e.name : 'error'}), using fallback`); // name only, no message
          cached = { config: null, until: now().getTime() + failMs };
        }
        inflight = null;
        return cached.config;
      })();
    }
    return inflight;
  }

  return async function handler(event) {
    const response = event.Records[0].cf.response;
    if (!REWRITE_STATUS.has(Number(response.status))) return response;
    if (originForbidsShared(response.headers)) return response;
    let value = FALLBACK_CACHE_CONTROL;
    try {
      const config = await getConfig();
      if (config) value = cacheControlFor(config, now());
    } catch {
      value = FALLBACK_CACHE_CONTROL;
    }
    response.headers = response.headers || {};
    response.headers['cache-control'] = [{ key: 'Cache-Control', value }];
    return response;
  };
}

let s3 = null;
async function loadFromS3() {
  const { S3Client, GetObjectCommand } = await import('@aws-sdk/client-s3'); // part of the Node.js runtime
  if (!s3) s3 = new S3Client({ region: 'us-east-1' });
  const out = await s3.send(new GetObjectCommand({ Bucket: CONFIG_BUCKET, Key: CONFIG_KEY }), { abortSignal: AbortSignal.timeout(2500) });
  return out.Body.transformToString();
}

export const handler = makeHandler({ loadText: loadFromS3 });
