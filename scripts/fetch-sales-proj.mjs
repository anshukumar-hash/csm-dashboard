#!/usr/bin/env node
// Sales → OB projection sheet -> sales_proj.json
//
// Sheet 18lA2BIfrgV0tM9QWkctduSk-hj48gdjcl4mmEuKbym8, gid 1836593254.
// Row 0 is a totals row, row 1 the header, data from row 2. Several meaningful
// columns have BLANK headers and are read by position:
//   C(2) = ARR · F(5) = OB Expected date (YYYY-MM-DD) · G(6) = expected ARR
// Named: A Account Name · B Manager · D Product · E PWS Type · H Current Status
//        I AE Name · J Owner · K Ownership Remark
//
// This sheet is NOT published, so it must be read via gviz (pub returns a
// sign-in page).
//
// Usage: node scripts/fetch-sales-proj.mjs
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const SHEET_ID = '18lA2BIfrgV0tM9QWkctduSk-hj48gdjcl4mmEuKbym8';
const GID = '1836593254';

function parseCSV(t) {
  const rows = []; let f = '', row = [], q = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else {
      if (c === '"') q = true;
      else if (c === ',') { row.push(f); f = ''; }
      else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
      else if (c === '\r') { /* skip */ }
      else f += c;
    }
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}

async function fetchCSV() {
  const url = `https://docs.google.com/spreadsheets/d/${SHEET_ID}/gviz/tq?tqx=out:csv&gid=${GID}`;
  let lastErr;
  for (let a = 1; a <= 4; a++) {
    try {
      const res = await fetch(url, { redirect: 'follow' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const text = await res.text();
      if (text.includes('<!DOCTYPE html') || text.includes('<html'))
        throw new Error('got HTML (sheet not shared publicly?)');
      return text;
    } catch (e) { lastErr = e; await new Promise(r => setTimeout(r, 1500 * a)); }
  }
  throw new Error('fetch failed: ' + lastErr?.message);
}

const str = v => (v == null ? '' : String(v).trim());
const money = v => { const n = Number(str(v).replace(/[$,\s]/g, '')); return Number.isFinite(n) ? n : 0; };

const C = { account:0, manager:1, arr:2, product:3, pws:4, obExpected:5, expArr:6,
            status:7, ae:8, owner:9, remark:10 };

const rows = parseCSV(await fetchCSV());
const data = rows.slice(2).filter(r => r && str(r[C.account]));

const out = data.map(r => ({
  account: str(r[C.account]), manager: str(r[C.manager]),
  arr: money(r[C.arr]), expArr: money(r[C.expArr]),
  product: str(r[C.product]), pws: str(r[C.pws]),
  obExpected: str(r[C.obExpected]),
  status: str(r[C.status]), ae: str(r[C.ae]), owner: str(r[C.owner]), remark: str(r[C.remark]),
}));

const byMonth = {};
for (const r of out) {
  const m = r.obExpected.slice(0, 7);
  if (!/^\d{4}-\d{2}$/.test(m)) continue;
  const b = (byMonth[m] = byMonth[m] || { n: 0, arr: 0, expArr: 0 });
  b.n += 1; b.arr += r.arr; b.expArr += r.expArr;
}

writeFileSync(join(ROOT, 'sales_proj.json'), JSON.stringify({
  generated_at: new Date().toISOString(),
  source: `Google Sheet ${SHEET_ID} gid ${GID} (Sales → OB projection)`,
  count: out.length, byMonth, rows: out,
}));
process.stderr.write(`Wrote ${out.length} rows -> sales_proj.json\n`);
for (const m of Object.keys(byMonth).sort())
  process.stderr.write(`  ${m}: ${byMonth[m].n} accts · ARR $${Math.round(byMonth[m].arr).toLocaleString()} · expected $${Math.round(byMonth[m].expArr).toLocaleString()}\n`);
