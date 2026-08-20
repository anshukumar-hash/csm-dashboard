#!/usr/bin/env node
// Fetch the churn / contraction tracker (gid 1421999984) -> churn_mtd.json
//
// Row 0 is a totals row, row 1 is the header, data starts at row 2.
// Some meaningful columns have blank headers, so they are read by position:
//   D (3)  = ARR lost            G (4)  = churn month (YYYY-MM)
// Named: F Product · C Customer Segment · G Region · J CSM Name · Q Category
//        (Churn / OB Churn / Contraction) · U Reason · V Regrettable
//        Y "Leader Approved" -> rows marked "Attempting Revival" are EXCLUDED
//        (per user: those accounts are not counted as churn yet).
//
// Usage: node scripts/fetch-churn.mjs
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const SHEET_ID = '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
const GID = '1421999984';
const EXCLUDE_APPROVAL = 'attempting revival';

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
const money = v => { const n = Number(str(v).replace(/[$,\s]/g, '')); return Number.isFinite(n) ? n : 0; };

const C = { eid:0, cust:1, seg:2, arr:3, month:4, product:5, region:6, ctype:7, csubtype:8,
            csm:9, plan:10, ageBucket:11, term:12, impact:15, category:16, reason:20,
            regret:21, remark:22, approval:24, leaderRemark:25 };

async function main() {
  const rows = parseCSV(await fetchCSV());
  const data = rows.slice(2).filter(r => r && (str(r[C.eid]) || str(r[C.cust])));

  const all = [], excluded = [];
  for (const r of data) {
    const productLine = str(r[C.product]);
    if (productLine !== 'Studio' && productLine !== 'Vini') continue;
    const rec = {
      productLine,
      eid: str(r[C.eid]), customer: str(r[C.cust]), seg: str(r[C.seg]),
      arr: money(r[C.arr]), month: str(r[C.month]), region: str(r[C.region]),
      ctype: str(r[C.ctype]), csubtype: str(r[C.csubtype]), csm: str(r[C.csm]),
      plan: str(r[C.plan]), ageBucket: str(r[C.ageBucket]),
      impact: str(r[C.impact]), category: str(r[C.category]), reason: str(r[C.reason]),
      regret: str(r[C.regret]), remark: str(r[C.remark]), approval: str(r[C.approval]),
    };
    if (rec.approval.toLowerCase() === EXCLUDE_APPROVAL) { excluded.push(rec); continue; }
    all.push(rec);
  }

  const byMonth = {};
  for (const r of all) {
    if (!r.month) continue;
    const key = r.productLine + '|' + r.month;
    const b = (byMonth[key] = byMonth[key] || { churn: { n: 0, arr: 0 }, contraction: { n: 0, arr: 0 }, obChurn: { n: 0, arr: 0 } });
    const k = r.category === 'Contraction' ? 'contraction' : r.category === 'OB Churn' ? 'obChurn' : 'churn';
    b[k].n += 1; b[k].arr += r.arr;
  }

  const payload = {
    generated_at: new Date().toISOString(),
    source: `Google Sheet ${SHEET_ID} gid ${GID} (Product = Studio + Vini); rows with Leader Approved = "Attempting Revival" excluded`,
    count: all.length, excludedCount: excluded.length,
    excluded: excluded.map(r => ({ customer: r.customer, productLine: r.productLine, arr: r.arr, month: r.month, category: r.category })),
    byMonth, rows: all,
  };
  writeFileSync(join(ROOT, 'churn_mtd.json'), JSON.stringify(payload));
  process.stderr.write(`Wrote ${all.length} churn rows (Studio + Vini) -> churn_mtd.json (excluded ${excluded.length} "Attempting Revival")\n`);
  for (const m of Object.keys(byMonth).sort()) {
    const b = byMonth[m];
    process.stderr.write(`  ${m}: churn ${b.churn.n} ($${Math.round(b.churn.arr).toLocaleString()}) · contraction ${b.contraction.n} ($${Math.round(b.contraction.arr).toLocaleString()}) · OB churn ${b.obChurn.n} ($${Math.round(b.obChurn.arr).toLocaleString()})\n`);
  }
  if (excluded.length) process.stderr.write(`  excluded: ${excluded.map(r => r.productLine + ' ' + r.customer + ' $' + Math.round(r.arr).toLocaleString()).join(', ')}\n`);
}
main().catch(e => { console.error(e); process.exit(1); });
