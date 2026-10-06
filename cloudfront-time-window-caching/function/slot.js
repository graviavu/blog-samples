import cf from 'cloudfront'; // runtime 2.0

// Option A of the post: a viewer request function adds a time slot to the cache key.
// SOURCE OF TRUTH. The template embeds this file (node scripts/check-function-sync.mjs --write regenerates it).
//
// KVS key "window", JSON value, UTC minutes since midnight, startMin < endMin (same UTC day):
//   {"startMin": 810, "endMin": 1200, "slotSeconds": 5, "rev": 1}
//
// Slot values (the cache key part): 'w<n>' in the window (n = epoch / slotSeconds, so no slot is ever reused),
// 'pre-<UTC date>-r<rev>' before the open and 'post-<UTC date>-r<rev>' after the close, so a pre-open entry
// can never be served after the close. 'f<n>' is the fail-closed slot (see below).
//
// Differences from the sketch in the post, on purpose:
//  - The record is validated. A missing key, unreadable JSON, wrong types, out-of-range numbers or
//    startMin >= endMin (a window across 00:00 UTC is not supported in part 1) FAIL CLOSED: the request gets a
//    short fallback slot ('f<n>', FALLBACK_SLOT_SECONDS long), so data is never older than that and the origin
//    load is bounded. The post's sketch returned the request unchanged, which would share one cache key (fail-open).
//  - The slot goes into the query string 'slot' or into the request header 'x-cache-slot', chosen by CARRIER.
//    Whatever the viewer sent under that name is replaced, so a viewer cannot pick its own cache key.
//    The cache policy lists only that one name, so the viewer's other query strings stay out of the key.

const kvs = cf.kvs();

const CARRIER = 'query'; // 'query' or 'header' (the template fills this in from SlotCarrier)
const HEADER_NAME = 'x-cache-slot';
const FALLBACK_SLOT_SECONDS = 5;

function isInt(v, lo, hi) {
  return typeof v === 'number' && isFinite(v) && Math.floor(v) === v && v >= lo && v <= hi;
}

function parseWindow(w) {
  if (!w || typeof w !== 'object') return null;
  const rev = w.rev === undefined ? 0 : w.rev;
  if (!isInt(w.startMin, 0, 1439) || !isInt(w.endMin, 1, 1440) || !isInt(w.slotSeconds, 1, 3600) || !isInt(rev, 0, 999999)) {
    return null;
  }
  if (w.startMin >= w.endMin) return null; // equal, or across midnight: unsupported
  return { startMin: w.startMin, endMin: w.endMin, slotSeconds: w.slotSeconds, rev: rev };
}

function slotFor(w, now) {
  const ms = now.getTime();
  if (w === null) return 'f' + Math.floor(ms / (FALLBACK_SLOT_SECONDS * 1000));
  const minute = now.getUTCHours() * 60 + now.getUTCMinutes();
  if (minute >= w.startMin && minute < w.endMin) {
    return 'w' + Math.floor(ms / (w.slotSeconds * 1000));
  }
  const phase = minute < w.startMin ? 'pre' : 'post';
  return phase + '-' + now.toISOString().slice(0, 10) + '-r' + w.rev;
}

async function handler(event) {
  const request = event.request;
  let w = null;
  try {
    w = parseWindow(await kvs.get('window', { format: 'json' }));
  } catch (e) {
    w = null; // key missing, store unavailable or value is not JSON: fail closed
  }
  const slot = slotFor(w, new Date());
  if (!request.querystring) request.querystring = {};
  if (CARRIER === 'header') {
    delete request.querystring.slot;
    request.headers[HEADER_NAME] = { value: slot };
  } else {
    delete request.headers[HEADER_NAME];
    request.querystring.slot = { value: slot };
  }
  return request;
}
