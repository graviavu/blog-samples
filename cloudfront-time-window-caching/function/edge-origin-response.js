'use strict';

// Option B of the post (optional second stack): a Lambda@Edge origin-response function rewrites Cache-Control
// by a fixed UTC window. SOURCE OF TRUTH. The template embeds this file; the five constants below are filled
// in from stack parameters at deploy time (Lambda@Edge has no environment variables). There is no data store:
// to change the window you deploy a new function version, which is the limit the post names.
//
// Runs only on cache misses. Errors (status 400 and above) are not rewritten unless REWRITE_ERRORS is true,
// which exists to test whether a rewritten header makes an error cacheable for the full lifetime (test T9).

const WINDOW_START_MIN = 0;   // UTC minutes since midnight, inclusive
const WINDOW_END_MIN = 1440;  // exclusive; start < end, same UTC day
const IN_TTL = 15;            // s-maxage inside the window, seconds
const OUT_TTL = 45;           // s-maxage outside the window, seconds
const REWRITE_ERRORS = false; // also rewrite status 400 and above

exports.handler = async (event) => {
  const response = event.Records[0].cf.response;
  const status = Number(response.status);
  if (status >= 400 && !REWRITE_ERRORS) return response;

  const now = new Date();
  const minute = now.getUTCHours() * 60 + now.getUTCMinutes();
  const inWindow = minute >= WINDOW_START_MIN && minute < WINDOW_END_MIN;
  const ttl = inWindow ? IN_TTL : OUT_TTL;
  response.headers['cache-control'] = [
    { key: 'Cache-Control', value: 'public, max-age=0, s-maxage=' + ttl },
  ];
  return response;
};
