#!/usr/bin/env node
// Build the Vini tab's data feed (vini_card.json) from Metabase card 12755.
//
// Card 12755 is daily: one row per rooftop × agent_type × day, with arr,
// touched_leads, qualified_leads, appointments, conversion_rate, plus segment /
// CSM / region / account type. From it we derive:
//   • grain  — the UNIQUE (team_id, agent_type) universe (Live only). This is
//     the Vini row list (replaces VINI_STAGE as the seed).
//   • daily  — the daily metric rows (Live only). Supplies the numbers
//     (replaces the daily Vini sheet).
// RoI is computed in the dashboard, per rooftop: apptValue = appointments ×
// apptValuePerAppt(agent); MRR = ARR/12; RoI = apptValue / MRR.
//
// Auth: Metabase API key via x-api-key. Local runs read .env.local; the CI
// workflow injects METABASE_API_KEY as a secret.
//
// Env: METABASE_API_KEY (required) · METABASE_BASE_URL (def https://metabase.spyne.ai)
//      METABASE_VINI_CARD (def 12755)

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
const CARD = (get('METABASE_VINI_CARD') || '12755').replace(/\D/g, '');
if (!KEY) { console.error('ERROR: METABASE_API_KEY not set (.env.local locally, or GitHub secret in CI).'); process.exit(1); }

const S = v => v == null ? '' : String(v);
const isLive = v => S(v).toLowerCase() === 'live';

// ---- fetch card 12755 ----
console.error(`Querying ${BASE}/api/card/${CARD} …`);
const res = await fetch(`${BASE}/api/card/${CARD}/query/json`, {
  method: 'POST', headers: { 'x-api-key': KEY, 'Content-Type': 'application/json' }, body: '{}',
});
if (!res.ok) { console.error(`ERROR: ${res.status} — ${(await res.text().catch(()=> '')).slice(0, 300)}`); process.exit(1); }
const raw = await res.json();
if (!Array.isArray(raw)) { console.error('Unexpected (non-array) response.'); process.exit(1); }
console.error(`Fetched ${raw.length} rows.`);

// ---- daily (Live only) + unique (team_id, agent_type) grain ----
const daily = [];
const grainMap = new Map();   // rid|agent -> {rid, agent, stage, rn, eid, en}  (latest-day identity)
let nonLive = 0;
for (const r of raw) {
  if (!isLive(r.rooftop_stage)) { nonLive++; continue; }
  const rid = S(r.team_id).trim(); if (!rid) continue;
  const agent = S(r.agent_type);
  const day = S(r.day).slice(0, 10);
  const row = {
    day, agent, rid, rn: S(r.rooftop_name), eid: S(r.enterprise_id).trim(), en: S(r.enterprise_name),
    ct: S(r.account_type), cst: S(r.account_sub_type), seg: S(r.customer_segment),
    csm: S(r.cs_poc_email).trim(), region: S(r.region_type),
    arr: Number(r.arr) || 0,
    t: Number(r.touched_leads) || 0, q: Number(r.qualified_leads) || 0,
    a: Number(r.appointments) || 0, cv: Number(r.conversion_rate) || 0,
  };
  daily.push(row);
  // grain: unique by (team_id, agent_type); keep latest-day identity fields
  const key = rid + '|' + agent;
  const g = grainMap.get(key);
  if (!g || day >= g._day) {
    grainMap.set(key, { rid, agent, stage: 'Live', rn: row.rn, eid: row.eid, en: row.en, _day: day });
  }
}
const grain = [...grainMap.values()].map(({ _day, ...g }) => g);
const rooftops = new Set(grain.map(g => g.rid)).size;
console.error(`Live: ${daily.length} daily rows · ${grain.length} unique (team_id, agent_type) across ${rooftops} rooftops (skipped ${nonLive} non-Live).`);

// ---- Vini Churned ARR — from the churn log sheet (Product = Vini) ----
// The card is Live-only, so churned ARR is not in it. Source: Google Sheet
// gid 1421999984, col D = churned ARR ($), col F = Product. Row 0 is a total,
// row 1 is the header, data starts at row 2. Fetched server-side (no CORS).
let churnedArrVini = 0, churnedRowsVini = 0;
try {
  const CS = process.env.VINI_CHURN_SHEET || '1H5cBuWmLD_roF_LV3foWII37PHbTqqNdzCcVGeAGU8A';
  const CG = process.env.VINI_CHURN_GID || '1421999984';
  const cr = await fetch(`https://docs.google.com/spreadsheets/d/${CS}/gviz/tq?tqx=out:json&gid=${CG}`);
  if (cr.ok) {
    const ct = await cr.text();
    const cj = JSON.parse(ct.slice(ct.indexOf('{'), ct.lastIndexOf('}') + 1));
    const crows = (cj.table && cj.table.rows) || [];
    for (let i = 2; i < crows.length; i++) {
      const c = crows[i].c || [];
      const prod = c[5] && c[5].v != null ? String(c[5].v).trim().toLowerCase() : '';
      const arr = c[3] && c[3].v != null ? Number(c[3].v) : 0;
      if (prod === 'vini') { churnedArrVini += arr; churnedRowsVini++; }
    }
    console.error(`Churned ARR (Vini) from sheet: ${Math.round(churnedArrVini)} across ${churnedRowsVini} rows.`);
  } else {
    console.error(`WARN: churn sheet fetch ${cr.status} — churned ARR defaults to 0.`);
  }
} catch (e) { console.error('WARN: churn sheet fetch failed:', e.message); }

// ---- write feed ----
const payload = JSON.stringify({
  grain, daily,
  churned_arr_vini: churnedArrVini, churned_rows_vini: churnedRowsVini,
  _meta: { card: CARD, base: BASE, generated: new Date().toISOString(),
           grain_rows: grain.length, rooftops, daily_rows: daily.length, non_live_skipped: nonLive,
           churned_arr_vini: Math.round(churnedArrVini), churned_rows_vini: churnedRowsVini },
});
for (const p of [path.join(repoRoot, 'vini_card.json'), path.join(repoRoot, 'vercel_deploy', 'vini_card.json')]) {
  fs.writeFileSync(p, payload);
  console.error('wrote', p, `(${(payload.length/1024).toFixed(0)} KB)`);
}
console.error('Done.');
