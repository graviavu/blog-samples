import cf from 'cloudfront'; // runtime 2.0

// TEST ONLY (EnableTestBehaviors). The FIRST version of the closed-period key from the post: 'closed-<date>',
// identical before the open and after the close. It exists to reproduce the flaw the post describes (test T3d):
// an entry cached before the open is still served after the close. Do not use this for anything real.
// SOURCE OF TRUTH. The template embeds this file. The window check is copied from slot.js.

const kvs = cf.kvs();

const CARRIER = 'query'; // 'query' or 'header' (the template fills this in from SlotCarrier)
const HEADER_NAME = 'x-cache-slot';
const FALLBACK_SLOT_SECONDS = 5;

function isInt(v, lo, hi) {
  return typeof v === 'number' && isFinite(v) && Math.floor(v) === v && v >= lo && v <= hi;
}

function parseWindow(w) {
  if (!w || typeof w !== 'object') return null;
  if (!isInt(w.startMin, 0, 1439) || !isInt(w.endMin, 1, 1440) || !isInt(w.slotSeconds, 1, 3600)) return null;
  if (w.startMin >= w.endMin) return null;
  return { startMin: w.startMin, endMin: w.endMin, slotSeconds: w.slotSeconds };
}

function slotFor(w, now) {
  const ms = now.getTime();
  if (w === null) return 'f' + Math.floor(ms / (FALLBACK_SLOT_SECONDS * 1000));
  const minute = now.getUTCHours() * 60 + now.getUTCMinutes();
  if (minute >= w.startMin && minute < w.endMin) {
    return 'w' + Math.floor(ms / (w.slotSeconds * 1000));
  }
  return 'closed-' + now.toISOString().slice(0, 10); // the flaw: no pre/post phase, no rev
}

async function handler(event) {
  const request = event.request;
  let w = null;
  try {
    w = parseWindow(await kvs.get('window', { format: 'json' }));
  } catch (e) {
    w = null;
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
