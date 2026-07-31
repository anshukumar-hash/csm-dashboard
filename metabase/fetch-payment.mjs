#!/usr/bin/env node
// Build the Payment Analysis feed (payment_data.json) from the invoices tab of
// the ARR sheet (gid 406922800). Public sheet via gviz — no auth.
//
// Columns used (spreadsheet letters):
//   B  Entity Name     → customer name
//   E  customer_status → invoice/payment status (overdue / paid / …)
//   F  invoice_number
//   G  date            → invoice RAISE date
//   H  due_date
//   L  currency_code
//   M  total           → invoice total (local currency)
//   N  balance         → outstanding balance (local currency)
//   V  EnterprisesID   → eid (join key to CSM / segment / manager / POD)
//   AA Final USD        → invoice total in USD
//   AB Final USD_Paid   → amount paid in USD
//   J  country
//   W  Billing Terms · X Service Type
//
// Outstanding in USD is derived per-invoice as (balance/total) × Final USD, so a
// partially-paid invoice contributes only its open share. RAG (aging) and the
// CSM/segment/manager/POD join are done CLIENT-side (they depend on "today" and
// on the dashboard's live enterprise→CSM mapping).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');

const SHEET = '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
const GID = '406922800';

const S = v => (v == null ? '' : String(v));
const num = v => { if (v == null || v === '') return 0; const n = (typeof v === 'number') ? v : Number(String(v).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? 0 : n; };
// gviz dates arrive as "Date(2026,6,16)" (month is 0-based) → ISO yyyy-mm-dd.
const gdate = v => {
  const m = String(v == null ? '' : v).match(/^Date\((\d+),(\d+),(\d+)/);
  if (!m) return '';
  const y = +m[1], mo = +m[2] + 1, d = +m[3];
  if (y < 1901) return ''; // gviz null-date sentinel (1899,11,30)
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
};
const cell = (c, i) => (c && c[i] ? (c[i].v != null ? c[i].v : (c[i].f != null ? c[i].f : null)) : null);

const url = `https://docs.google.com/spreadsheets/d/${SHEET}/gviz/tq?tqx=out:json&gid=${GID}&_cb=${Date.now()}`;
console.error(`Fetching payment sheet gid=${GID} …`);
const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
const txt = await res.text();
const json = JSON.parse(txt.slice(txt.indexOf('{'), txt.lastIndexOf('}') + 1));
const rowsIn = json.table.rows || [];

const rows = [];
for (const r of rowsIn) {
  const c = r.c || [];
  const customer = S(cell(c, 1)).trim();      // B
  const invoice = S(cell(c, 5)).trim();        // F
  if (!customer && !invoice) continue;
  const total = num(cell(c, 12));              // M
  const balance = num(cell(c, 13));            // N
  const finalUsd = num(cell(c, 26));           // AA
  const finalUsdPaid = num(cell(c, 27));       // AB
  // USD-equivalent of the open balance.
  const openFrac = total > 0 ? balance / total : (balance > 0 ? 1 : 0);
  const outstandingUsd = Math.round(openFrac * finalUsd * 100) / 100;
  rows.push({
    eid: S(cell(c, 21)).trim(),                // V
    customer,
    company: S(cell(c, 2)).trim(),             // C
    status: S(cell(c, 4)).trim().toLowerCase(),// E
    invoice,
    raiseIso: gdate(cell(c, 6)),               // G
    dueIso: gdate(cell(c, 7)),                 // H
    currency: S(cell(c, 11)).trim(),           // L
    total, balance,
    finalUsd, finalUsdPaid,
    outstandingUsd,
    country: S(cell(c, 9)).trim(),             // J
    billing: S(cell(c, 22)).trim(),            // W
    serviceType: S(cell(c, 23)).trim(),        // X
  });
}

const out = {
  rows,
  _meta: {
    gid: GID,
    rows: rows.length,
    generated: new Date().toISOString(),
    note: 'Payment invoices from ARR sheet gid 406922800. outstandingUsd = (balance/total)×FinalUSD. RAG (aging) + CSM/segment/manager/POD join are computed client-side.',
  },
};
const text = JSON.stringify(out);
for (const p of [path.join(repoRoot, 'payment_data.json'), path.join(repoRoot, 'vercel_deploy', 'payment_data.json')]) {
  fs.writeFileSync(p, text);
  console.error('wrote', p, `(${text.length} bytes)`);
}
console.error(`Done: ${rows.length} invoices, ${new Set(rows.map(r => r.eid).filter(Boolean)).size} enterprises.`);
