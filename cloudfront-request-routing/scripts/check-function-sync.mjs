// Single source of truth check: the function code in function/*.js must be exactly the code the
// CloudFormation templates deploy. Usage:
//   node scripts/check-function-sync.mjs           check (exit 1 on any difference)
//   node scripts/check-function-sync.mjs --write   rewrite the template blocks from function/*.js
// A block is the literal text under "FunctionCode:" / "ZipFile:" that follows a "# SOURCE: function/<file>" line.
// The only allowed difference is a documented list of values the template fills in with !Sub.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const write = process.argv.includes('--write');

// file -> template -> [[text in function file, text in template]]
const TARGETS = [
  { template: 'template.yaml', file: 'route.js', subs: [
      ["const ROUTE_ATTRIBUTE = 'x-backend';", "const ROUTE_ATTRIBUTE = '${RouteAttribute}';"],
      ['const SEND_HOST_HEADER = false;', 'const SEND_HOST_HEADER = ${SendHostHeader};'],
      ["const OAC_MODE = 'region';", "const OAC_MODE = '${OacMode}';"],
    ] },
  { template: 'template.yaml', file: 'probe.js', subs: [] },
  {
    template: 'template-lambda-edge.yaml', file: 'edge-origin-request.js',
    subs: [["'route-a': 'origin-a.example.net'", "'route-a': '${OriginAHost}'"], ["'route-b': 'origin-b.example.net'", "'route-b': '${OriginBHost}'"]],
  },
];

let failed = false;
for (const t of TARGETS) {
  const tplPath = join(root, t.template);
  const lines = readFileSync(tplPath, 'utf8').split('\n');
  const marker = lines.findIndex((l) => l.trim() === `# SOURCE: function/${t.file}` || l.trim().startsWith(`# SOURCE: function/${t.file} `));
  if (marker < 0) { console.error(`FAIL ${t.template}: no "# SOURCE: function/${t.file}" marker`); failed = true; continue; }
  const start = lines.findIndex((l, i) => i > marker && (/^\s+(FunctionCode|ZipFile): (!Sub )?\|\s*$/.test(l) || /^\s+- \|\s*$/.test(l)));
  if (start < 0) { console.error(`FAIL ${t.template}: no literal code block after marker for ${t.file}`); failed = true; continue; }
  const indent = lines[start + 1].match(/^ */)[0].length;
  let end = start + 1;
  while (end < lines.length && (lines[end].trim() === '' || lines[end].match(/^ */)[0].length >= indent)) end++;
  while (lines[end - 1].trim() === '') end--;

  let expected = readFileSync(join(root, 'function', t.file), 'utf8').replace(/\n+$/, '');
  for (const [from, to] of t.subs) {
    if (!expected.includes(from)) { console.error(`FAIL ${t.file}: substitution anchor not found: ${from}`); failed = true; }
    expected = expected.replace(from, to);
  }
  const expectedLines = expected.split('\n').map((l) => (l === '' ? '' : ' '.repeat(indent) + l));
  const actualLines = lines.slice(start + 1, end);

  if (expectedLines.join('\n') === actualLines.join('\n')) {
    console.log(`ok   ${t.template} contains function/${t.file}`);
  } else if (write) {
    lines.splice(start + 1, end - start - 1, ...expectedLines);
    writeFileSync(tplPath, lines.join('\n'));
    console.log(`wrote ${t.template} from function/${t.file}`);
  } else {
    console.error(`FAIL ${t.template} differs from function/${t.file} (run with --write to update the template)`);
    failed = true;
  }
}

// ---- variants: function/variants.json is the one table; the template mapping and variants.sh must match it.
import { readFileSync as rf } from 'node:fs';
const variants = JSON.parse(rf(join(root, 'function', 'variants.json'), 'utf8'));
let vfail = false;
const tpl = rf(join(root, 'template.yaml'), 'utf8');
for (const [name, v] of Object.entries(variants)) {
  const line = `${name}: {SendHostHeader: '${v.sendHostHeader}', OacMode: '${v.oacMode}'}`;
  if (!tpl.includes(line)) { console.error(`FAIL template.yaml Mappings lack: ${line}`); vfail = true; }
  if (!tpl.includes(`      - ${name}\n`) && !new RegExp(`AllowedValues: \\[[^\\]]*\\b${name}\\b`).test(tpl)) { console.error(`FAIL template.yaml RouteVariant does not allow ${name}`); vfail = true; }
}
const sh = rf(join(root, 'variants.sh'), 'utf8');
const m = sh.match(/# BEGIN variant table[^\n]*\n(?:VARIANT_TABLE=")([\s\S]*?)"\n# END variant table/);
const want = Object.entries(variants).map(([n, v]) => `${n} ${v.originAuth}`).join('\n');
if (!m || m[1].trim() !== want) { console.error('FAIL variants.sh variant table differs from function/variants.json. Expected:\n' + want); vfail = true; }
for (const [name, v] of Object.entries(variants)) {
  if (v.oacMode === 'none' && v.originAuth === 'AWS_IAM' && !['V5'].includes(name)) { /* allowed, documented inheritance case */ }
  if (v.oacMode === 'off' && v.originAuth !== 'NONE') { console.error(`FAIL ${name}: oac off requires public origins`); vfail = true; }
}
if (!vfail) console.log(`ok   ${Object.keys(variants).length} variants consistent (variants.json, template mapping, variants.sh)`);
process.exit(failed || vfail ? 1 : 0);
