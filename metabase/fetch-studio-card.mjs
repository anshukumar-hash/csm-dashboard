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
const BASE = (get('METABASE_BASE_URL') || 'https://metabase.spyne.ai').replace(/\/+$/, '');
// Public Metabase question ("Studio Dump_Console") — no auth. Same 20-column
// grain as card 12114 (enterprise/rooftop identity + monthly VINs + pendency +
// score + contracted_arr). Env STUDIO_PUBLIC_UUID overrides.
const PUBLIC_UUID = get('STUDIO_PUBLIC_UUID') || '81af28d2-cd3e-431c-8380-8f3eae935084';
const ARR_SHEET = '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
const ARR_GID = '1341638818';

const S = v => v == null ? '' : String(v);
const num = v => { if (v == null) return 0; const n = (typeof v === 'number') ? v : Number(String(v).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? 0 : n; };

// ---- 1. Studio rooftop universe ----
// Source = the CSM ClickHouse backend when configured (CSM_BACKEND_URL +
// CSM_BACKEND_TOKEN), else the public Metabase question. The backend's
// `studio_rooftops` query returns the SAME columns, so this is a transparent
// source swap with automatic fallback — a backend blip can never break the feed.
const BACKEND_URL = get('CSM_BACKEND_URL').replace(/\/+$/, '');
const BACKEND_TOKEN = get('CSM_BACKEND_TOKEN');
async function fromBackend(name) {
  const r = await fetch(`${BACKEND_URL}/query`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${BACKEND_TOKEN}`, 'User-Agent': 'Mozilla/5.0' },
    body: JSON.stringify({ name }),
  });
  if (!r.ok) throw new Error(`backend ${name} → ${r.status} ${(await r.text().catch(() => '')).slice(0, 200)}`);
  const j = await r.json();
  if (!j || j.success !== true || !Array.isArray(j.rows)) throw new Error(`backend ${name} → bad payload`);
  return j.rows;
}
async function fromPublic() {
  // The public Metabase question is a heavy query that intermittently 504s /
  // times out under load. Retry with backoff so a transient gateway timeout
  // can't fail the whole feed (which would silently keep stale month columns).
  // Keep the total bounded well under the CI job timeout: 3 attempts × 90s +
  // short backoff ≈ 5 min worst case. If the public question is down that long
  // the workflow guard keeps the last-good studio_card.json rather than hanging.
  const MAX = 3;
  let lastErr;
  for (let attempt = 1; attempt <= MAX; attempt++) {
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 90000);
      let res;
      try {
        res = await fetch(`${BASE}/api/public/card/${PUBLIC_UUID}/query/json`, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: ctl.signal });
      } finally { clearTimeout(timer); }
      if (!res.ok) {
        const body = (await res.text().catch(() => '')).slice(0, 300);
        // 5xx / 429 are transient; retry. 4xx (except 429) is fatal.
        if (res.status >= 500 || res.status === 429) throw new Error(`public card ${PUBLIC_UUID} → ${res.status} (transient) — ${body}`);
        throw Object.assign(new Error(`public card ${PUBLIC_UUID} → ${res.status} — ${body}`), { fatal: true });
      }
      return await res.json();
    } catch (e) {
      lastErr = e;
      if (e.fatal || attempt === MAX) throw e;
      const wait = Math.min(30000, 3000 * attempt);
      console.error(`WARN: public question attempt ${attempt}/${MAX} failed (${e.message}) — retrying in ${wait / 1000}s …`);
      await new Promise(r => setTimeout(r, wait));
    }
  }
  throw lastErr;
}
let card;
if (BACKEND_URL && BACKEND_TOKEN) {
  try { console.error(`Querying backend studio_rooftops @ ${BACKEND_URL} …`); card = await fromBackend('studio_rooftops'); }
  catch (e) { console.error(`WARN: backend failed (${e.message}) — falling back to public question.`); card = await fromPublic().catch(err => { console.error(`ERROR: public fallback also failed: ${err.message}`); process.exit(1); }); }
} else {
  console.error(`Querying public question ${PUBLIC_UUID} …`);
  card = await fromPublic().catch(err => { console.error(`ERROR: ${err.message}`); process.exit(1); });
}
if (!Array.isArray(card) || card.length < 100) { console.error(`ERROR: source returned ${Array.isArray(card) ? card.length : 'non-array'} rows (<100) — keeping last-good.`); process.exit(1); }
console.error(`Studio public question: ${card.length} rooftops.`);

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
const arrByEid = {}, arrRecByEid = {}, prodByEid = {};
for (const r of (arrJson.table.rows || []).slice(1)) {   // row 0 = header
  const c = r.c || [];
  const eid = S(cellV(c[0])).trim(); if (!eid) continue;
  // Product CLASSIFICATION across ALL rows/stages (authoritative product for the
  // enterprise). Combos like "Studio+Vini" set both flags. Used to drop rooftops
  // that card 12114 wrongly lists but are actually Vini-only accounts.
  const pl = S(cellV(c[2])).toLowerCase();
  const cls = prodByEid[eid] || (prodByEid[eid] = { studio: false, vini: false });
  if (pl.includes('stud')) cls.studio = true;
  if (pl.includes('vin')) cls.vini = true;
  // Studio ARR (Live/Future-Churn) — powers arr/mrr + the union of missing accts.
  if (!pl.includes('stud')) continue;
  const stage = S(cellV(c[3])).trim();
  if (!KEEP_STAGE.has(stage)) continue;
  const arr = num(c[ARR_COL] ? (c[ARR_COL].v ?? c[ARR_COL].f) : 0);
  arrByEid[eid] = arr;
  arrRecByEid[eid] = {
    eid, arr, stage,
    cust: S(cellV(c[1])).trim(),
    ct: S(cellV(c[6])).trim(), cst: S(cellV(c[7])).trim(),
    seg: S(cellV(c[8])).trim(), csm: S(cellV(c[9])).trim(), region: S(cellV(c[12])).trim(),
  };
}
// eids the ARR sheet marks Vini-only (Vini, no Studio) → NOT Studio rooftops.
const isViniOnly = eid => { const p = prodByEid[eid]; return !!(p && p.vini && !p.studio); };
console.error(`ARR sheet: ${Object.keys(arrByEid).length} Studio Live/Future-Churn enterprises.`);

// ---- 3. drop card rooftops that are Vini-only per the ARR sheet (card 12114
// wrongly lists some Vini accounts as Studio rooftops), then count rooftops per
// enterprise for the equal ARR split ----
let dropped = 0;
const cardStudio = card.filter(r => { if (isViniOnly(S(r.enterprise_id).trim())) { dropped++; return false; } return true; });
console.error(`Dropped ${dropped} Vini-only rooftops that card 12114 mislabelled as Studio.`);
const rcByEid = {};
cardStudio.forEach(r => { const e = S(r.enterprise_id).trim(); rcByEid[e] = (rcByEid[e] || 0) + 1; });

// ---- 4. build rows (identity/usage/carr from card; arr/mrr split from sheet) ----
let matched = 0, totArr = 0;
const rows = cardStudio.map(r => {
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
    u_jul: num(r["Jul'26"] ?? r["Jul'26_MTD"]), u_aug: num(r["Aug'26_MTD"] ?? r["Aug'26"]),
    u_mtd: num(r.mtd_vins),
    arr: Math.round(arr * 100) / 100, mrr: Math.round(arr / 12 * 100) / 100,
    carr: num(r.contracted_arr),
    // Returned by card 12114, whose WHERE clause is etd.stage IN ('Live') — so
    // the product database itself confirms this rooftop is live today.
    mbLive: true,
  };
}).filter(r => r.rid);

// Union: Live/Future-Churn accounts present in the ARR sheet but MISSING from
// card 12114. Two very different things land here and the data cannot tell them
// apart on its own:
//   (a) billing-only rooftops the usage registry genuinely does not carry, and
//   (b) accounts that have actually CHURNED, where the hand-maintained ARR sheet
//       simply has not been updated yet.
// Chapman Chevrolet was case (b): still "Live" on the sheet, already gone from
// the product database, and shown as churned in the admin tool — yet it was
// being added back here and counted as a live rooftop.
// They are still added, so nothing silently disappears, but tagged mbLive:false
// so the dashboard can separate "the product DB says live" from "only the
// spreadsheet says live".
const cardEidSet = new Set(cardStudio.map(r => S(r.enterprise_id).trim()));
let added = 0;
for (const eid of Object.keys(arrRecByEid)) {
  if (cardEidSet.has(eid)) continue;
  const a = arrRecByEid[eid];
  rows.push({
    rid: eid, rn: a.cust, en: a.cust, eid,
    ct: a.ct, cst: a.cst, seg: a.seg, csm: a.csm || 'Unassigned CSM', region: a.region,
    ws: 0, ws_link: '', pen: 0,
    u_jan: 0, u_feb: 0, u_mar: 0, u_apr: 0, u_may: 0, u_jun: 0, u_jul: 0, u_aug: 0, u_mtd: 0,
    arr: Math.round(a.arr * 100) / 100, mrr: Math.round(a.arr / 12 * 100) / 100, carr: 0,
    mbLive: false,
  });
  totArr += a.arr; added++;
}
console.error(`Added ${added} ARR-sheet Live/Future-Churn accounts missing from card 12114 (tagged mbLive:false).`);

const out = {
  rows,
  _meta: {
    source: 'public_question', public_uuid: PUBLIC_UUID, arr_gid: ARR_GID,
    rooftops: rows.length, arr_matched: matched, arr_unmatched: rows.length - matched,
    total_arr: Math.round(totArr),
    generated_note: 'Studio feed — identity/VINs/CARR from public Metabase question (Studio Dump_Console); ARR from sheet gid 1341638818 (Studio, Live/Future Churn), split equally across each enterprise’s rooftops; MRR = ARR/12.',
  },
};
const outPath = path.join(repoRoot, 'studio_card.json');
fs.writeFileSync(outPath, JSON.stringify(out));
console.error(`Wrote ${outPath}: ${rows.length} rooftops · ARR matched ${matched}/${rows.length} · total ARR $${Math.round(totArr).toLocaleString()}`);
