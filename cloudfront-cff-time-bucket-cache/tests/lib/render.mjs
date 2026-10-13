// Test helper: pulls the CloudFront Function code out of cfn/stack.yaml, fills in the three parameters (what !Sub does) and loads it.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// The text of the block under "FunctionCode: !Sub |", de-indented, still with ${...} placeholders.
export function templateCode(root = ROOT) {
  const lines = readFileSync(join(root, 'cfn', 'stack.yaml'), 'utf8').split('\n');
  const i = lines.findIndex((l) => /^\s*FunctionCode: !Sub \|\s*$/.test(l));
  if (i < 0) throw new Error('FunctionCode block not found');
  const indent = lines[i + 1].match(/^ */)[0].length;
  const out = [];
  for (let j = i + 1; j < lines.length; j++) {
    const l = lines[j];
    if (l.trim() !== '' && l.match(/^ */)[0].length < indent) break;
    out.push(l.slice(indent));
  }
  while (out.length && out[out.length - 1] === '') out.pop();
  return out.join('\n') + '\n';
}

export function render(code, p) {
  return code.replace('${StartHour}', String(p.StartHour)).replace('${EndHour}', String(p.EndHour)).replace('${BucketSeconds}', String(p.BucketSeconds));
}

// Load rendered code with a fake clock. Returns { handler, bucketFor }.
export function load(code, nowMs) {
  class FakeDate extends Date {
    constructor(...a) { if (a.length) super(...a); else super(nowMs); }
    static now() { return nowMs; }
  }
  // eslint-disable-next-line no-new-func
  return new Function('Date', code + '\nreturn { handler: handler, bucketFor: bucketFor };')(FakeDate);
}
