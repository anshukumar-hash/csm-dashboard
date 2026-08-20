#!/usr/bin/env node
// Fetch the ARR / lifecycle sheet (gid 1341638818) -> arr_sheet.json
//
// This is the enterprise-level source of truth for Studio ARR and lifecycle
// stage. Row 0 is a totals row, row 1 holds the header, data starts at row 2.
// Several meaningful columns have BLANK headers, so they are read by position:
//   E (4)  = effective date (churn date for Churned / OB Churn / Sales Drop,
//            planned date for Future Churn; always blank for Live)
//   Q (16) = ARR   <- the ARR column the dashboard uses
//   K (10) = a second ARR-ish column (kept as arrK for reconciliation only)
//
// Usage: node scripts/fetch-arr-sheet.mjs
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const SHEET_ID = '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
const GID = '1341638818';

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
      if (text.includes('<!DOCTYPE html') || text.includes('<html')) throw new Error('got HTML (sheet not public?)');
      return text;
    } catch (e) { lastErr = e; await new Promise(r => setTimeout(r, 1500 * a)); }
  }
  throw new Error('fetch failed: ' + lastErr?.message);
}

const str = v => (v == null ? '' : String(v).trim());
const money = v => {
  const s = str(v).replace(/[$,\s]/g, '');
  if (!s || s === '-') return 0;
  const n = Number(s);
  return Number.isFinite(n) ? n : 0;
};
// "18-Dec-2026" / "1-Jul-2026" -> "2026-12"
const MON = 'JanFebMarAprMayJunJulAugSepOctNovDec';
function toMonth(v) {
  const s = str(v); if (!s) return null;
  let m = s.match(/^(\d{1,2})-([A-Za-z]{3})-(\d{4})$/);
  if (m) { const mo = MON.indexOf(m[2]) / 3 + 1; if (mo >= 1) return m[3] + '-' + String(mo).padStart(2, '0'); }
  m = s.match(/^(\d{4})-(\d{2})/); if (m) return m[1] + '-' + m[2];
  return null;
}

const C = { eid:0, cust:1, product:2, stage:3, date:4, plan:5, ctype:6, csubtype:7,
            seg:8, csm:9, arrK:10, rag:11, region:12, arr:16, obPoc:29, ae:30 };

async function main() {
  const rows = parseCSV(await fetchCSV());
  const data = rows.slice(2).filter(r => r && (str(r[C.eid]) || str(r[C.cust])));

  const out = [];
  for (const r of data) {
    const productLine = str(r[C.product]);
    if (productLine !== 'Studio' && productLine !== 'Vini') continue;
    const stage = str(r[C.stage]);
    out.push({
      productLine,
      eid: str(r[C.eid]),
      customer: str(r[C.cust]),
      stage,
      date: str(r[C.date]),
      month: toMonth(r[C.date]),          // churn/effective month
      arr: money(r[C.arr]),               // col Q — the ARR the dashboard uses
      arrK: money(r[C.arrK]),             // col K — kept for reconciliation only
      plan: str(r[C.plan]),
      ctype: str(r[C.ctype]),
      csubtype: str(r[C.csubtype]),
      seg: str(r[C.seg]),
      csm: str(r[C.csm]),
      rag: str(r[C.rag]),
      region: str(r[C.region]),
      obPoc: str(r[C.obPoc]),
      ae: str(r[C.ae]),
    });
  }

  const byProduct = {};
  for (const r of out) {
    const p = (byProduct[r.productLine] = byProduct[r.productLine] || {});
    const s = (p[r.stage] = p[r.stage] || { n: 0, arr: 0 });
    s.n += 1; s.arr += r.arr;
  }

  const payload = {
    generated_at: new Date().toISOString(),
    source: `Google Sheet ${SHEET_ID} gid ${GID} (Product = Studio + Vini); ARR = column Q`,
    count: out.length, byProduct, rows: out,
  };
  writeFileSync(join(ROOT, 'arr_sheet.json'), JSON.stringify(payload));
  process.stderr.write(`Wrote ${out.length} rows (Studio + Vini) -> arr_sheet.json\n`);
  for (const p of Object.keys(byProduct))
    for (const k of Object.keys(byProduct[p]))
      process.stderr.write(`  ${p} ${k}: ${byProduct[p][k].n} · $${Math.round(byProduct[p][k].arr).toLocaleString()}\n`);
}
main().catch(e => { console.error(e); process.exit(1); });
