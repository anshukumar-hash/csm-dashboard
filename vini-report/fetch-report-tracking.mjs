#!/usr/bin/env node
// Fetch Vini "Report Sent" tracking from the daily-calls tracker and publish it
// as vini_report_tracking.json — the runtime source for the dashboard's Report
// Sent column. Replaces the old DIRECT roi_digest_runs Supabase read, which
// returns empty from the browser (the anon key is RLS-scoped out of that table).
//
// Auth flow (server-side ONLY — the credential must never ship to the public
// dashboard page):
//   1. POST /api/tracker/login  {id,password}            -> { token }
//   2. GET  /api/tracker/rooftops-data?anchor=YYYY-MM-DD  (Bearer token)
//      -> { runs: [ { team_id, department, cadence, local_date, status, ... } ] }
//   rooftops-data is the gated, RLS-safe endpoint (service key server-side). It
//   only returns rooftops whose department is flagged is_live.
//
// Env (all injected from GitHub Actions secrets at run time — NONE hard-coded):
//   TRACKER_USER      (required)  tracker login id       (e.g. spyne-devansh)
//   TRACKER_PASSWORD  (required)  tracker login password
//   TRACKER_API_URL   default https://vini-daily-calls.vercel.app
//   REPORT_ANCHOR     optional YYYY-MM-DD anchor (defaults to today, UTC)

import fs from 'node:fs';
import path from 'node:path';

const BASE = (process.env.TRACKER_API_URL || 'https://vini-daily-calls.vercel.app').replace(/\/+$/, '');
const USER = process.env.TRACKER_USER;
const PASS = process.env.TRACKER_PASSWORD;
const ANCHOR = process.env.REPORT_ANCHOR || new Date().toISOString().slice(0, 10);

if (!USER || !PASS) {
  console.error('ERROR: TRACKER_USER / TRACKER_PASSWORD not set. Add them under '
    + 'Settings → Secrets and variables → Actions.');
  process.exit(1);
}

// ---- 1) login → bearer token ----
const loginRes = await fetch(`${BASE}/api/tracker/login`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ id: USER, password: PASS }),
});
if (!loginRes.ok) {
  console.error(`ERROR: login ${loginRes.status} — ${(await loginRes.text().catch(() => '')).slice(0, 200)}`);
  process.exit(1);
}
const token = (await loginRes.json().catch(() => ({}))).token;
if (!token) { console.error('ERROR: login returned no token.'); process.exit(1); }
console.log('✓ tracker login ok');

// ---- 2) read the gated rooftops-data endpoint (anchored at today) ----
const dataRes = await fetch(`${BASE}/api/tracker/rooftops-data?anchor=${ANCHOR}`, {
  headers: { Authorization: `Bearer ${token}` },
});
if (!dataRes.ok) {
  console.error(`ERROR: rooftops-data ${dataRes.status} — ${(await dataRes.text().catch(() => '')).slice(0, 200)}`);
  process.exit(1);
}
const json = await dataRes.json();
const runs = Array.isArray(json && json.runs) ? json.runs : [];
console.log(`Fetched ${runs.length} runs (anchor ${ANCHOR}).`);

// ---- 3) transform → { [team_id]: [{ d, dept, s }] } (daily cadence only) ----
// Same per-rooftop shape the dashboard's VINI_REPORT_TRACKING already expects,
// so fetchViniReportTracking() can consume it with no downstream changes.
const byTeam = {};
let kept = 0;
for (const r of runs) {
  if (String(r.cadence || '') !== 'daily') continue;
  const rid = r.team_id != null ? String(r.team_id).trim() : '';
  if (!rid) continue;
  (byTeam[rid] = byTeam[rid] || []).push({ d: r.local_date, dept: r.department, s: String(r.status || '') });
  kept++;
}
console.log(`Kept ${kept} daily runs across ${Object.keys(byTeam).length} rooftops.`);

// ---- 4) write feed (repo root + vercel_deploy copy) ----
const repoRoot = path.resolve(process.cwd(), '..');
const payload = JSON.stringify({
  runs_by_team: byTeam,
  _meta: { anchor: ANCHOR, source: 'tracker rooftops-data', generated: new Date().toISOString(),
           rooftops: Object.keys(byTeam).length, runs: kept },
});
for (const p of [path.join(repoRoot, 'vini_report_tracking.json'), path.join(repoRoot, 'vercel_deploy', 'vini_report_tracking.json')]) {
  fs.writeFileSync(p, payload);
  console.log('wrote', p, `(${payload.length} bytes)`);
}
console.log('Done.');
