// sigv4.mjs - minimal AWS Signature Version 4 signer for GET/HEAD/POST requests, WebCrypto only (works in Cloudflare Workers
// and in Node 20+). No dependency. Tested against the examples in the AWS Signature Version 4 documentation (test/sigv4.test.mjs).
// Signs: host, x-amz-date, x-amz-content-sha256 (optional), x-amz-security-token (if a session token is given) and any
// extra headers listed in `signHeaders`. All other headers are sent unsigned, which SigV4 allows.

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

export async function sha256Hex(data) {
  const bytes = typeof data === 'string' ? enc.encode(data) : data;
  return hex(await crypto.subtle.digest('SHA-256', bytes));
}

async function hmac(keyBytes, data) {
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, typeof data === 'string' ? enc.encode(data) : data));
}

export async function signingKey(secret, date8, region, service) {
  const kDate = await hmac(enc.encode('AWS4' + secret), date8);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}

// RFC 3986 unreserved set only, as SigV4 requires (encodeURIComponent leaves !'()* alone).
const uriEncode = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());

function canonicalQuery(searchParams) {
  const pairs = [];
  for (const [k, v] of searchParams) pairs.push([uriEncode(k), uriEncode(v)]);
  pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
  return pairs.map(([k, v]) => `${k}=${v}`).join('&');
}

// Non-S3 services: the path is URI-encoded once more on top of its already encoded form (double encoding).
function canonicalPath(pathname) {
  return pathname.split('/').map((seg) => uriEncode(seg)).join('/') || '/';
}

/**
 * @param {object} o
 * @param {string} o.method @param {string|URL} o.url @param {Record<string,string>} [o.headers] extra headers to send
 * @param {string[]} [o.signHeaders] lower-case names of `headers` to include in the signature
 * @param {string} o.accessKeyId @param {string} o.secretAccessKey @param {string} [o.sessionToken]
 * @param {string} o.region @param {string} o.service
 * @param {string} [o.payloadHash] hex SHA-256 of the body, or 'UNSIGNED-PAYLOAD' (default: hash of the empty string)
 * @param {boolean} [o.includeContentSha256] send x-amz-content-sha256 (default true; Lambda web functions require it)
 * @param {Date} [o.now]
 * @returns {Promise<{headers: Record<string,string>, canonicalRequest: string, signature: string}>}
 */
export async function signRequest(o) {
  const url = new URL(o.url);
  const now = o.now || new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ''); // 20150830T123600Z
  const date8 = amzDate.slice(0, 8);
  const payloadHash = o.payloadHash || (await sha256Hex(''));
  const includeSha = o.includeContentSha256 !== false;

  const toSign = { host: url.host, 'x-amz-date': amzDate };
  if (includeSha) toSign['x-amz-content-sha256'] = payloadHash;
  if (o.sessionToken) toSign['x-amz-security-token'] = o.sessionToken;
  for (const name of o.signHeaders || []) {
    const v = (o.headers || {})[name];
    if (v === undefined) throw new Error(`signHeaders names a header that was not given: ${name}`);
    toSign[name.toLowerCase()] = String(v).trim().replace(/\s+/g, ' ');
  }
  const names = Object.keys(toSign).sort();
  const canonicalHeaders = names.map((n) => `${n}:${toSign[n]}\n`).join('');
  const signedHeaders = names.join(';');
  const canonicalRequest = [
    o.method.toUpperCase(),
    canonicalPath(url.pathname),
    canonicalQuery(url.searchParams),
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const scope = `${date8}/${o.region}/${o.service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonicalRequest)].join('\n');
  const key = await signingKey(o.secretAccessKey, date8, o.region, o.service);
  const signature = hex(await hmac(key, stringToSign));

  const headers = { ...(o.headers || {}), 'x-amz-date': amzDate };
  if (includeSha) headers['x-amz-content-sha256'] = payloadHash;
  if (o.sessionToken) headers['x-amz-security-token'] = o.sessionToken;
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${o.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  return { headers, canonicalRequest, signature };
}
