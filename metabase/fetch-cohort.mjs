#!/usr/bin/env node
// Build cohort_data.json for the Retention Explorer's Cohort Retention view,
// from the cohort sheet (per-account monthly ARR snapshots). Mirrors the
// Spyne-Cohort-Explorer reference: each account has a 16-month ARR series
// (Mar'25 → Jun'26); the dashboard groups accounts by first active month and
// projects gross (GRR) / net (NRR) retention, with click-through to accounts.
//
// Sheet: 1Q-C73O… default tab. Rows 0-1 = totals, row 2 = header, rows 3+ =
// accounts: B=Enterprise ID, C=Customer, D=Customer Type, E=Product, F..U =
// 16 monthly ARR values. gviz is not CORS-fetchable from the browser, so this
// runs server-side (scheduled) and publishes cohort_data.json (same-origin).
//
// Output: { months:[16 labels], recs:[{eid,n,ct,p,s:[16 numbers]}], total:[16] }

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const SHEET = '1Q-C73O6hexVHJ-JFMKHvra9lKab3GXABCVxYDVEGCwA';
// Fallback month list (sheet layout as of Jun'26). The live list is
// AUTO-DETECTED from the sheet's header row below, so newly-added month
// columns (Jul'26, Aug'26, …) flow through without a code change.
const MONTHS_FALLBACK = ["Mar'25","Apr'25","May'25","Jun'25","Jul'25","Aug'25","Sep'25","Oct'25","Nov'25","Dec'25","Jan'26","Feb'26","Mar'26","Apr'26","May'26","Jun'26"];
const M0 = 5;   // month values start at col F(5)

const url = `https://docs.google.com/spreadsheets/d/${SHEET}/gviz/tq?tqx=out:json&_cb=${Date.now()}`;
console.error(`Fetching cohort sheet …`);
const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
const txt = await res.text();
const j = JSON.parse(txt.slice(txt.indexOf('{'), txt.lastIndexOf('}') + 1));
const rows = j.table.rows || [];
const V = c => c ? c.v : null;

// Auto-detect the month labels from the header row (row index 2): consecutive
// cells from col F matching Mon'YY. Falls back to the hardcoded list if the
// header is missing/odd, so a sheet glitch can never blank the explorer.
let MONTHS = MONTHS_FALLBACK;
{
  const hdr = rows[2] && rows[2].c ? rows[2].c : null;
  if (hdr) {
    const det = [];
    for (let i = M0; i < hdr.length; i++) {
      const lab = String((hdr[i] && hdr[i].v) ?? '').trim();
      if (/^[A-Z][a-z]{2}'\d{2}$/.test(lab)) det.push(lab); else break;
    }
    if (det.length >= 12) MONTHS = det;
  }
  if (MONTHS.length !== MONTHS_FALLBACK.length) console.error(`month auto-detect: ${MONTHS.length} months (${MONTHS[MONTHS.length-1]} latest)`);
}
const MN = MONTHS.length;
const num = c => { if (!c) return 0; const n = (typeof c.v === 'number') ? c.v : Number(String(c.f ?? c.v ?? '').replace(/[^0-9.\-]/g, '')); return isNaN(n) ? 0 : n; };
const normP = p => { p = String(p || '').toLowerCase(); return p.indexOf('vin') === 0 ? 'Vini' : (p.indexOf('stud') === 0 ? 'Studio' : (p || 'Studio')); };

// Totals row (index 0) → the month-by-month total ARR (for a sanity chip).
const total = rows[0] ? rows[0].c.slice(M0, M0 + MN).map(num) : new Array(MN).fill(0);

const recs = [];
for (const r of rows.slice(3)) {   // skip 2 total rows + 1 header
  const c = r.c || [];
  const eid = String(V(c[1]) ?? '').trim();
  const name = String(V(c[2]) ?? '').trim();
  if (!eid && !name) continue;
  const s = [];
  for (let i = 0; i < MN; i++) s.push(Math.round((num(c[M0 + i])) * 100) / 100);
  if (!s.some(x => x > 0)) continue;   // never active → skip
  recs.push({ eid, n: name, ct: String(V(c[3]) ?? '').trim(), p: normP(V(c[4])), s });
}

const out = { months: MONTHS, recs, total,
  _meta: { accounts: recs.length, generated_from: 'sheet 1Q-C73O… default tab', latest_total: Math.round(total[MN - 1]) } };
const payload = JSON.stringify(out);
for (const p of [path.join(repoRoot, 'cohort_data.json'), path.join(repoRoot, 'vercel_deploy', 'cohort_data.json')]) {
  fs.writeFileSync(p, payload);
  console.error(`wrote ${p}`);
}
console.error(`cohort_data.json: ${recs.length} accounts · ${MN} months · latest total ARR $${Math.round(total[MN - 1]).toLocaleString()}`);
