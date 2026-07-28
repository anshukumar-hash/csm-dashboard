#!/usr/bin/env node
// Build the Studio rooftop feed (studio_card.json) from Metabase card 12114 +
// the ARR sheet — REPLACES the old Google Sheet gid=603796861 (now empty).
//
//   • Rooftop universe + identity + monthly VINs + pendency + CARR ← card 12114
//     (1 row per Studio rooftop). Columns: enterprise_id, enterprise_name,
//     rooftop_id, rooftop_name, account_type, account_sub_type, customer_segment,
//     cs_poc_email, region_type, overall_score, url, pending_over_6h,
//     Jan'26…Jun'26, mtd_vins, contracted_arr.
//   • ARR ← sheet 1H5cBuWmLD… gid=1341638818, col Q ("ARR"), filtered to
//     Product = Studio AND Stage ∈ (Live, Future Churn). ARR is PER-ENTERPRISE;
//     it is split EQUALLY across that enterprise's rooftops (arr = entArr /
//     #rooftops), and MRR = arr / 12 (per user spec, 2026-07).
//
// Payment (t1/t2/t3/prag) and tickets/comm are NOT here — sync.ps1 joins payment
// by eid, and the dashboard computes tickets/comm from Ticket_Dump / CSAT at
// render. This feed carries only the identity/usage/ARR base.
//
// Auth: Metabase API key via x-api-key (local .env.local, or the CI secret).
// Env: METABASE_API_KEY (required) · METABASE_BASE_URL (def https://metabase.spyne.ai)
//      METABASE_STUDIO_CARD (def 12114)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const envFile = {};
const envPath = path.join(repoRoot, '.env.local');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    if (line.trim().startsWith('#')) continue;
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) envFile[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
const get = k => process.env[k] || envFile[k] || '';
const KEY  = get('METABASE_API_KEY');
const BASE = (get('METABASE_BASE_URL') || 'https://metabase.spyne.ai').replace(/\/+$/, '');
const CARD = (get('METABASE_STUDIO_CARD') || '12114').replace(/\D/g, '');
const ARR_SHEET = '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
const ARR_GID = '1341638818';
if (!KEY) { console.error('ERROR: METABASE_API_KEY not set (.env.local locally, or GitHub secret in CI).'); process.exit(1); }

const S = v => v == null ? '' : String(v);
const num = v => { if (v == null) return 0; const n = (typeof v === 'number') ? v : Number(String(v).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? 0 : n; };

// ---- 1. Metabase card 12114 → Studio rooftop universe ----
console.error(`Querying ${BASE}/api/card/${CARD} …`);
const res = await fetch(`${BASE}/api/card/${CARD}/query/json`, {
  method: 'POST', headers: { 'x-api-key': KEY, 'Content-Type': 'application/json' }, body: '{}',
});
if (!res.ok) { console.error(`ERROR: card ${CARD} → ${res.status} — ${(await res.text().catch(()=> '')).slice(0, 300)}`); process.exit(1); }
const card = await res.json();
if (!Array.isArray(card) || !card.length) { console.error('ERROR: card returned no rows.'); process.exit(1); }
console.error(`Card ${CARD}: ${card.length} rooftops.`);

// ---- 2. ARR sheet → eid → ARR (Studio, Live/Future Churn, col Q index 16) ----
const arrUrl = `https://docs.google.com/spreadsheets/d/${ARR_SHEET}/gviz/tq?tqx=out:json&gid=${ARR_GID}&_cb=${Date.now()}`;
console.error(`Fetching ARR sheet gid=${ARR_GID} …`);
const arrRes = await fetch(arrUrl, { headers: { 'User-Agent': 'Mozilla/5.0' } });
const arrTxt = await arrRes.text();
const arrJson = JSON.parse(arrTxt.slice(arrTxt.indexOf('{'), arrTxt.lastIndexOf('}') + 1));
const cellV = c => c ? c.v : null;
const ARR_COL = 16;   // col Q — matches SEG_BASE.studio when summed
const KEEP_STAGE = new Set(['Live', 'Future Churn']);
// Full per-enterprise record (arr + identity) so we can both (a) supply ARR to
// card rooftops and (b) add Live/Future-Churn accounts that card 12114 is
// MISSING as their own rows (else those live accounts vanish from the view).
const arrByEid = {}, arrRecByEid = {};
for (const r of (arrJson.table.rows || []).slice(1)) {   // row 0 = header
  const c = r.c || [];
  if (S(cellV(c[2])).trim().toLowerCase() !== 'studio') continue;
  const stage = S(cellV(c[3])).trim();
  if (!KEEP_STAGE.has(stage)) continue;
  const eid = S(cellV(c[0])).trim(); if (!eid) continue;
  const arr = num(c[ARR_COL] ? (c[ARR_COL].v ?? c[ARR_COL].f) : 0);
  arrByEid[eid] = arr;
  arrRecByEid[eid] = {
    eid, arr, stage,
    cust: S(cellV(c[1])).trim(),
    ct: S(cellV(c[6])).trim(), cst: S(cellV(c[7])).trim(),
    seg: S(cellV(c[8])).trim(), csm: S(cellV(c[9])).trim(), region: S(cellV(c[12])).trim(),
  };
}
console.error(`ARR sheet: ${Object.keys(arrByEid).length} Studio Live/Future-Churn enterprises.`);

// ---- 3. rooftop count per enterprise (from card) → equal ARR split ----
const rcByEid = {};
card.forEach(r => { const e = S(r.enterprise_id).trim(); rcByEid[e] = (rcByEid[e] || 0) + 1; });

// ---- 4. build rows (identity/usage/carr from card; arr/mrr split from sheet) ----
let matched = 0, totArr = 0;
const rows = card.map(r => {
  const eid = S(r.enterprise_id).trim();
  const entArr = arrByEid[eid];
  const arr = (entArr != null) ? entArr / (rcByEid[eid] || 1) : 0;
  if (entArr != null) matched++;
  totArr += arr;
  const csm = S(r.cs_poc_email).trim() || 'Unassigned CSM';
  return {
    rid: S(r.rooftop_id), rn: S(r.rooftop_name), en: S(r.enterprise_name), eid,
    ct: S(r.account_type), cst: S(r.account_sub_type), seg: S(r.customer_segment),
    csm, region: S(r.region_type),
    ws: num(r.overall_score), ws_link: S(r.url), pen: num(r.pending_over_6h),
    u_jan: num(r["Jan'26"]), u_feb: num(r["Feb'26"]), u_mar: num(r["Mar'26"]),
    u_apr: num(r["Apr'26"]), u_may: num(r["May'26"]), u_jun: num(r["Jun'26"]),
    u_mtd: num(r.mtd_vins),
    arr: Math.round(arr * 100) / 100, mrr: Math.round(arr / 12 * 100) / 100,
    carr: num(r.contracted_arr),
  };
}).filter(r => r.rid);

// Union: Live/Future-Churn accounts present in the ARR sheet but MISSING from
// card 12114 (billing-only rooftops the usage registry doesn't have). Add each
// as its own row keyed by eid so no live account disappears from the view. They
// carry ARR/MRR but no VINs/CARR (card has none for them).
const cardEidSet = new Set(card.map(r => S(r.enterprise_id).trim()));
let added = 0;
for (const eid of Object.keys(arrRecByEid)) {
  if (cardEidSet.has(eid)) continue;
  const a = arrRecByEid[eid];
  rows.push({
    rid: eid, rn: a.cust, en: a.cust, eid,
    ct: a.ct, cst: a.cst, seg: a.seg, csm: a.csm || 'Unassigned CSM', region: a.region,
    ws: 0, ws_link: '', pen: 0,
    u_jan: 0, u_feb: 0, u_mar: 0, u_apr: 0, u_may: 0, u_jun: 0, u_mtd: 0,
    arr: Math.round(a.arr * 100) / 100, mrr: Math.round(a.arr / 12 * 100) / 100, carr: 0,
  });
  totArr += a.arr; added++;
}
console.error(`Added ${added} ARR-sheet Live/Future-Churn accounts missing from card 12114.`);

const out = {
  rows,
  _meta: {
    card: CARD, arr_gid: ARR_GID,
    rooftops: rows.length, arr_matched: matched, arr_unmatched: rows.length - matched,
    total_arr: Math.round(totArr),
    generated_note: 'Studio feed — identity/VINs/CARR from Metabase card 12114; ARR from sheet gid 1341638818 (Studio, Live/Future Churn), split equally across each enterprise’s rooftops; MRR = ARR/12.',
  },
};
const outPath = path.join(repoRoot, 'studio_card.json');
fs.writeFileSync(outPath, JSON.stringify(out));
console.error(`Wrote ${outPath}: ${rows.length} rooftops · ARR matched ${matched}/${rows.length} · total ARR $${Math.round(totArr).toLocaleString()}`);
