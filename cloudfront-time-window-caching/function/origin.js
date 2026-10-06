'use strict';

// Test origin for the cloudfront-time-window-caching sample (a Lambda function URL behind CloudFront OAC).
// It answers fixed test routes with controllable Cache-Control / Expires headers and a JSON body that carries a
// per-response unique id and a timestamp, so a cache hit is provable (the same id comes back) and the number of
// origin fetches in a burst is the number of distinct ids.
//
// Safety rules for this file: the route is the last path segment and must be an exact key of ROUTES; nothing
// from the request is copied into a header or the body, except two booleans and the slot value, and the slot
// value only if it matches a strict allow-list pattern. It holds no secrets and reads no data store.

const crypto = require('node:crypto');

const ROUTES = new Map();
const add = (name, spec) => ROUTES.set(name, spec);

add('none', {});                                              // no Cache-Control, no Expires
add('nostore', { cc: 'no-store' });
add('private', { cc: 'private' });
add('nocache', { cc: 'no-cache' });
add('public-nomax', { cc: 'public' });                        // public without max-age
add('maxage-0', { cc: 'public, max-age=0' });
add('maxage-5', { cc: 'public, max-age=5' });
add('maxage-30', { cc: 'public, max-age=30' });
add('maxage-3600', { cc: 'public, max-age=3600' });
add('smaxage-only', { cc: 'public, s-maxage=5' });            // s-maxage without max-age
add('both-5', { cc: 'public, max-age=0, s-maxage=5' });       // the post's worked example
add('both-14400', { cc: 'public, max-age=0, s-maxage=14400' });
add('expires-past', { expires: 'Thu, 01 Jan 1970 00:00:00 GMT' });                      // Expires only, in the past
add('maxage-expires', { cc: 'public, max-age=5', expires: 'Fri, 31 Dec 2100 23:59:59 GMT' }); // both: max-age wins
add('etag', { cc: 'public, max-age=5', etag: '"tw-fixed-etag"' });                       // conditional requests
add('slow', { cc: 'no-store', delayMs: 1000 });               // overlap for the request collapsing test
for (const code of [400, 403, 404, 500, 503]) {
  add(`error-${code}`, { status: code });                                    // error without Cache-Control
  add(`error-${code}-cc`, { status: code, cc: 'public, s-maxage=60' });      // error with Cache-Control
}

const SLOT = /^(w[0-9]{1,12}|f[0-9]{1,12}|(pre|post)-[0-9]{4}-[0-9]{2}-[0-9]{2}-r[0-9]{1,6}|closed-[0-9]{4}-[0-9]{2}-[0-9]{2})$/;

function slotOf(value) { // returns the value only if it matches the allow-list, never anything else
  return typeof value === 'string' && SLOT.test(value) ? value : null;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

exports.handler = async (event) => {
  const path = typeof event.rawPath === 'string' ? event.rawPath.slice(0, 300) : '';
  const name = path.split('/').pop();
  const spec = ROUTES.has(name) ? ROUTES.get(name) : null;
  const h = event.headers || {};
  const q = event.queryStringParameters || {};

  if (!spec) {
    return {
      statusCode: 404,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
      body: JSON.stringify({ error: 'unknown route' }),
    };
  }

  if (spec.delayMs) await sleep(spec.delayMs);

  const headers = { 'content-type': 'application/json', 'x-sample-origin': 'cloudfront-time-window-caching' };
  if (spec.cc) headers['cache-control'] = spec.cc;
  if (spec.expires) headers.expires = spec.expires;
  if (spec.etag) headers.etag = spec.etag;

  // Conditional request: CloudFront sends If-None-Match when it revalidates an expired object that has an ETag.
  if (spec.etag && h['if-none-match'] === spec.etag) {
    return { statusCode: 304, headers };
  }

  const slot = slotOf(q.slot);
  const slotHeader = slotOf(h['x-cache-slot']);
  const body = {
    id: crypto.randomUUID(),                 // unique per origin response
    ts: new Date().toISOString(),
    epoch: Date.now(),
    route: name,                             // an exact ROUTES key, not request input
    status: spec.status || 200,
    sentCacheControl: spec.cc || null,
    sawSlot: Object.prototype.hasOwnProperty.call(q, 'slot'),
    slot,                                    // allow-listed value or null
    slotInvalid: Object.prototype.hasOwnProperty.call(q, 'slot') && slot === null,
    sawSlotHeader: typeof h['x-cache-slot'] === 'string',
    slotHeader,
    slotHeaderInvalid: typeof h['x-cache-slot'] === 'string' && slotHeader === null,
  };
  return { statusCode: spec.status || 200, headers, body: JSON.stringify(body) };
};
