// Lambda@Edge origin-response function: no cache in business hours, long cache outside, and an object cached just
// before the window opens expires AT the opening.
//
// Reads one S3 object with path rules (kept 30 s in memory, parsed once):
//   {"rules":[{"path":"/prices/*","startMin":480,"endMin":1020,"inTtl":0,"outTtl":14400}, ...],
//    "default":{"startMin":480,"endMin":1020,"inTtl":0,"outTtl":14400}}          ("default" is optional)
// The rule for the request URI (event.Records[0].cf.request.uri, query string stripped) is chosen by exact path or trailing-*
// prefix, the LONGEST matching pattern wins, case-sensitive. No rule and no default: s-maxage=0. A malformed rule is skipped
// (only its index is logged, never its content). Then it computes the time since 00:00 UTC (seconds precision) and sets
//   Cache-Control: public, max-age=0, s-maxage=<ttl>
//   (all of the following per matched rule)
//   startMin*60 <= secondsOfDay < endMin*60  -> inTtl   (0 means CloudFront does not cache the object)
//   otherwise                                -> min(outTtl, seconds until the next opening), floored, never below 0
// "Next opening" is today's start if it is still ahead, otherwise tomorrow's start (86400 - now + start). The cap is
// computed on every invocation from the current time; only the window itself is read from S3 (and kept 30 s in memory).
//
// Clock note: the Lambda clock and the CloudFront edge clock can differ by a few seconds, and CloudFront counts the TTL from
// when it receives the response. The seconds are floored, so an object may expire a few seconds EARLY, never late by design.
//
// Rules: only 200, 203, 204 and 206 are rewritten (errors, redirects and 304 are left alone). A response is also left
// untouched when the origin says Cache-Control private, no-store or no-cache, or sets a cookie (set-cookie): the
// origin knows better than a clock, and a shared cache must not keep per-user content.
// Any problem reading or parsing the config gives s-maxage=0, never a long TTL.
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

// A window is {startMin,endMin,inTtl,outTtl}: 0 <= startMin < endMin <= 1440 (one window, same UTC day), integer TTLs >= 0.
export function parseWindow(c) {
  if (c === null || typeof c !== 'object' || Array.isArray(c)) return null;
  const { startMin, endMin, inTtl, outTtl } = c;
  if (!isInt(startMin, 0, 1439) || !isInt(endMin, 1, 1440) || startMin >= endMin) return null;
  if (!isInt(inTtl, 0, MAX_TTL_SECONDS) || !isInt(outTtl, 0, MAX_TTL_SECONDS)) return null;
  return { startMin, endMin, inTtl, outTtl };
}

// "/exact/path" or "/prefix/*" (the * only at the very end). No spaces or control characters, at most 1024 characters.
export function parsePattern(path) {
  if (typeof path !== 'string' || path.length < 1 || path.length > 1024 || path[0] !== '/') return null;
  if (/[\s\u0000-\u001f\u007f?#]/.test(path)) return null;
  const star = path.indexOf('*');
  if (star === -1) return { path, prefix: false, key: path };
  if (star !== path.length - 1) return null;
  return { path, prefix: true, key: path.slice(0, -1) };
}

// Returns {rules:[{path,prefix,key,window}], default: window|null}, or null when the text is not a usable config at all.
// Bad rules are skipped; only the index is logged.
export function parseConfig(text) {
  let c;
  try { c = JSON.parse(text); } catch { return null; }
  if (c === null || typeof c !== 'object' || Array.isArray(c)) return null;
  if (c.rules !== undefined && !Array.isArray(c.rules)) return null;
  const rules = [];
  (c.rules || []).forEach((r, i) => {
    const pat = r && typeof r === 'object' ? parsePattern(r.path) : null;
    const window = pat ? parseWindow(r) : null;
    if (!pat || !window) { console.log(`rule ${i} skipped (malformed)`); return; }
    rules.push({ ...pat, window });
  });
  let def = null;
  if (c.default !== undefined) {
    def = parseWindow(c.default);
    if (!def) console.log('default skipped (malformed)');
  }
  return { rules, default: def };
}

// The window for a request URI: query string stripped, exact path beats any prefix, the longest prefix wins, the first of
// equal patterns wins, case-sensitive (the URI is matched as CloudFront gives it, not decoded). null = no rule, no default.
export function selectWindow(config, uri) {
  let path = typeof uri === 'string' ? uri : '';
  const q = path.indexOf('?');
  if (q !== -1) path = path.slice(0, q);
  let best = null;
  for (const r of config.rules) {
    if (r.prefix ? !path.startsWith(r.key) : path !== r.key) continue;
    if (!r.prefix) return r.window;                                  // exact: cannot be beaten
    if (best === null || r.key.length > best.key.length) best = r;   // strictly longer only: first of equals wins
  }
  return best ? best.window : config.default;
}

export function minutesSinceMidnightUtc(date) {
  return date.getUTCHours() * 60 + date.getUTCMinutes();
}

// Seconds since 00:00 UTC, with the fraction (milliseconds), so that flooring a remaining time can only make it shorter.
export function secondsSinceMidnightUtc(date) {
  return date.getUTCHours() * 3600 + date.getUTCMinutes() * 60 + date.getUTCSeconds() + date.getUTCMilliseconds() / 1000;
}

const sane = (v) => (Number.isFinite(v) && v > 0 ? Math.floor(v) : 0); // NaN, negative, below 1 -> 0

// Seconds of the TTL for "now". startMin is inclusive, endMin is exclusive.
export function ttlSecondsFor(config, date) {
  const now = secondsSinceMidnightUtc(date);
  const start = config.startMin * 60;
  const end = config.endMin * 60;
  if (now >= start && now < end) return sane(config.inTtl);
  const untilOpen = now < start ? start - now : 86400 - now + start; // after the close: tomorrow's opening
  return sane(Math.min(config.outTtl, untilOpen));
}

export function cacheControlFor(config, date) {
  return `public, max-age=0, s-maxage=${ttlSecondsFor(config, date)}`;
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
      if (config) {
        const uri = event.Records[0].cf.request && event.Records[0].cf.request.uri;
        const window = selectWindow(config, uri);
        if (window) value = cacheControlFor(window, now());   // no rule and no default: stays at the fallback s-maxage=0
      }
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
