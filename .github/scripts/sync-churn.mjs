#!/usr/bin/env node
// ============================================================
// sync-churn.mjs — fetch the "Spyne | Churn" Metabase public dashboard and
// write a flat churn_data.json the dashboard's "Churn Intelligence" tab reads.
//
// The Metabase public dashboard exposes 3 table cards, one per signal status:
//   Open/In Progress (dashcard 361 / card 423)
//   Resolved         (dashcard 362 / card 424)
//   Dismissed        (dashcard 363 / card 425)
//
// Metabase v0.62 public-result endpoint (no /query suffix, returns 202 + body):
//   GET /api/public/dashboard/{uuid}/dashcard/{dashcardId}/card/{cardId}
//   -> { status, data: { cols:[{name,...}], rows:[[...], ...] } }
//
// We flatten each card to an array of {colName: value} objects and write both
// ./churn_data.json (source) and ./vercel_deploy/churn_data.json (served copy).
// Run every 15 min by .github/workflows/sync-churn.yml; also runnable locally.
// ============================================================
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const BASE = 'https://metabase.arali.ai';
const UUID = '6a4344e4-fad4-4ab0-99bd-a29dac43129d';
const CARDS = [
  { key: 'open',      dashcard: 361, card: 423 },
  { key: 'resolved',  dashcard: 362, card: 424 },
  { key: 'dismissed', dashcard: 363, card: 425 },
];

async function fetchCard({ key, dashcard, card }) {
  const url = `${BASE}/api/public/dashboard/${UUID}/dashcard/${dashcard}/card/${card}`;
  const res = await fetch(url, { headers: { accept: 'application/json' } });
  // Public result endpoint returns 202 (Accepted) on success, body is the result.
  if (res.status !== 200 && res.status !== 202) {
    throw new Error(`${key}: HTTP ${res.status} from ${url}`);
  }
  const json = await res.json();
  const data = json.data || {};
  const cols = (data.cols || []).map(c => c.name);
  const rows = data.rows || [];
  const out = rows.map(r => {
    const o = {};
    cols.forEach((name, i) => { o[name] = r[i]; });
    // Normalize ARR to whole US dollars. Metabase's `arr_cents` column actually
    // holds the dollar figure (per business definition, e.g. 7500 => $7,500);
    // the `arr` column is that value / 100. Prefer arr_cents when present (the
    // resolved card); otherwise recover it as arr*100 (verified identical to
    // arr_cents on every resolved row). After this, o.arr is always US dollars.
    const dollars = (o.arr_cents !== undefined && o.arr_cents !== null && o.arr_cents !== '')
      ? Number(o.arr_cents)
      : Math.round((Number(o.arr) || 0) * 100);
    o.arr = dollars;
    return o;
  });
  return { rows: out, cols };
}

async function main() {
  const result = {
    generated_at: new Date().toISOString(),
    source: 'Spyne | Churn (Metabase public dashboard)',
    dashboard_url: `${BASE}/public/dashboard/${UUID}`,
    counts: {},
    open: [],
    resolved: [],
    dismissed: [],
  };

  for (const c of CARDS) {
    const { rows, cols } = await fetchCard(c);
    result[c.key] = rows;
    result.counts[c.key] = rows.length;
    console.log(`${c.key}: ${rows.length} rows (${cols.length} cols)`);
  }

  const targets = ['churn_data.json', 'vercel_deploy/churn_data.json'];
  const payload = JSON.stringify(result);
  for (const t of targets) {
    mkdirSync(dirname(t) === '' ? '.' : dirname(t), { recursive: true });
    writeFileSync(t, payload);
    console.log(`wrote ${t} (${payload.length} bytes)`);
  }
}

main().catch(err => { console.error(err); process.exit(1); });
