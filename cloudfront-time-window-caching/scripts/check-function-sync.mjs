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
  { template: 'template.yaml', file: 'origin.js', subs: [] },
  { template: 'template.yaml', file: 'slot.js', subs: [["const CARRIER = 'query';", "const CARRIER = '${SlotCarrier}';"]] },
  { template: 'template.yaml', file: 'slot-legacy.js', subs: [["const CARRIER = 'query';", "const CARRIER = '${SlotCarrier}';"]] },
  {
    template: 'template-lambda-edge.yaml', file: 'edge-origin-response.js',
    subs: [
      ['const WINDOW_START_MIN = 0;', 'const WINDOW_START_MIN = ${WindowStartMin};'],
      ['const WINDOW_END_MIN = 1440;', 'const WINDOW_END_MIN = ${WindowEndMin};'],
      ['const IN_TTL = 15;', 'const IN_TTL = ${InTtl};'],
      ['const OUT_TTL = 45;', 'const OUT_TTL = ${OutTtl};'],
      ['const REWRITE_ERRORS = false;', 'const REWRITE_ERRORS = ${RewriteErrors};'],
    ],
  },
];

let failed = false;
for (const t of TARGETS) {
  const tplPath = join(root, t.template);
  const lines = readFileSync(tplPath, 'utf8').split('\n');
  const marker = lines.findIndex((l) => l.trim() === `# SOURCE: function/${t.file}` || l.trim().startsWith(`# SOURCE: function/${t.file} `));
  if (marker < 0) { console.error(`FAIL ${t.template}: no "# SOURCE: function/${t.file}" marker`); failed = true; continue; }
  const start = lines.findIndex((l, i) => i > marker && /^\s+(FunctionCode|ZipFile): (!Sub )?\|\s*$/.test(l));
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
process.exit(failed ? 1 : 0);
