import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

export function readSource(name) {
  return readFileSync(join(root, 'function', name), 'utf8');
}

// Loads function/route.js with a stub for the 'cloudfront' module.
// route.js is an ES module for the CloudFront runtime; here we swap the import line for the stub
// and evaluate the rest unchanged.
export function loadRoute({ store = {}, attribute, updateThrows = false, getThrows = false } = {}) {
  let src = readSource('route.js');
  if (attribute) {
    src = src.replace(/const ROUTE_ATTRIBUTE = '[^']*';/, `const ROUTE_ATTRIBUTE = '${attribute}';`);
  }
  if (!src.includes("import cf from 'cloudfront';")) throw new Error('import line not found');
  src = src.replace("import cf from 'cloudfront';", 'const cf = __cf;');
  const calls = { updates: [], reads: [] };
  const stub = {
    kvs: () => ({
      exists: async (k) => { calls.reads.push(['exists', k]); return Object.prototype.hasOwnProperty.call(store, k); },
      get: async (k) => {
        calls.reads.push(['get', k]);
        if (getThrows) throw new Error('store unavailable');
        if (!Object.prototype.hasOwnProperty.call(store, k)) throw new Error('key not found');
        return store[k];
      },
    }),
    updateRequestOrigin: (o) => {
      if (updateThrows) throw new Error('bad origin');
      calls.updates.push(o);
    },
  };
  const handler = new Function('__cf', `${src}\nreturn handler;`)(stub);
  return { handler, calls };
}

export function event(headerName, value) {
  const headers = {};
  if (value !== undefined) headers[headerName] = { value };
  return { request: { method: 'GET', uri: '/same.json', querystring: {}, headers, cookies: {} } };
}
