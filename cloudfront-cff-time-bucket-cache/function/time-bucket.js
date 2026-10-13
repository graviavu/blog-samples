// Viewer-request CloudFront Function (runtime cloudfront-js-2.0).
// Inside the daily UTC window [startHour, endHour) it sets the request header x-cache-bust to the current time bucket, so the
// cache key changes every bucketSeconds. Outside the window it sets nothing. In both cases a viewer-supplied x-cache-bust is
// removed first, so a client can never choose its own cache key. startHour > endHour means the window wraps past midnight.
var CFG = { startHour: ${StartHour}, endHour: ${EndHour}, bucketSeconds: ${BucketSeconds} };

function isInt(n, min, max) {
  return typeof n === 'number' && isFinite(n) && n === Math.floor(n) && n >= min && n <= max;
}

// Returns the bucket as a string, or '' when the time is outside the window or the settings are unusable (fail to long cache).
function bucketFor(cfg, nowMs) {
  if (!isInt(cfg.startHour, 0, 23) || !isInt(cfg.endHour, 0, 24) || !isInt(cfg.bucketSeconds, 1, 86400)) { return ''; }
  if (cfg.startHour === cfg.endHour) { return ''; }
  if (typeof nowMs !== 'number' || !isFinite(nowMs)) { return ''; }
  var hour = new Date(nowMs).getUTCHours();
  var inWindow = cfg.startHour < cfg.endHour
    ? (hour >= cfg.startHour && hour < cfg.endHour)
    : (hour >= cfg.startHour || hour < cfg.endHour);
  if (!inWindow) { return ''; }
  return String(Math.floor(nowMs / 1000 / cfg.bucketSeconds));
}

function handler(event) {
  var request = event.request;
  delete request.headers['x-cache-bust'];
  var bucket = bucketFor(CFG, new Date().getTime());
  if (bucket !== '') { request.headers['x-cache-bust'] = { value: bucket }; }
  return request;
}
