#!/usr/bin/env node
// Day-level historical snapshot of the dashboard → Supabase.
// Loads the dashboard in a headless browser and reuses ITS OWN functions
// (getStudio / getVini / computeOverview / computeOvOps) so the stored numbers
// match the UI exactly, then upserts date-stamped rows into Supabase (idempotent
// on the primary key, so re-running the same day overwrites rather than dupes).
//
// Env (GitHub Actions secrets):
//   SUPABASE_URL          — https://iglxkivlamzyshidbakm.supabase.co
//   SUPABASE_SERVICE_KEY  — service_role key (Settings → API). Bypasses RLS for writes.
//   SNAPSHOT_DATE         — optional YYYY-MM-DD override (defaults to today, UTC)
import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { chromium } from 'playwright';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TYPES = { '.html':'text/html', '.json':'application/json', '.js':'text/javascript', '.css':'text/css', '.png':'image/png', '.svg':'image/svg+xml' };
const SUPA_URL = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const SUPA_KEY = process.env.SUPABASE_SERVICE_KEY;
const today = process.env.SNAPSHOT_DATE || new Date().toISOString().slice(0, 10);

// 1) Serve repo + load the dashboard.
const server = http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || '/').split('?')[0]);
  if (p === '/') p = '/index.html';
  const f = path.join(ROOT, p);
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end('nf'); return; }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, r));
const port = server.address().port;

const browser = await chromium.launch({ args: ['--no-sandbox'] });
let data;
try {
  const page = await browser.newPage();
  await page.goto(`http://localhost:${port}/index.html`, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForFunction(() => typeof getStudio === 'function' && typeof computeOverview === 'function', { timeout: 30000 });
  // Kick off the Arali signal feed so signal-based metrics (arali_open_signals,
  // action 'signals') reflect real counts instead of 0, then wait for it.
  await page.evaluate(() => { try { if (typeof loadChurn === 'function' && typeof _churnState !== 'undefined' && _churnState === 'idle') loadChurn(); } catch (e) {} });
  await page.waitForFunction(() => typeof _churnState === 'undefined' || _churnState === 'ready' || _churnState === 'error', { timeout: 25000 }).catch(() => {});
  // Wait for the adoption + 360-bucket feeds so feature_adoption / pendency_360 actions aren't 0.
  await page.waitForFunction(() => (typeof ROOFTOP_ADOPTION === 'undefined' || Object.keys(ROOFTOP_ADOPTION).length > 0) && (typeof VINS_BUCKETS === 'undefined' || Object.keys(VINS_BUCKETS).length > 0), { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(2000); // settle other async (usage/tickets)
  data = await page.evaluate((date) => {
    const num = v => { const n = Number(v); return isFinite(n) ? n : null; };
    // ---- raw Studio rooftops (with computed RAGs, via ovStudioAcct) ----
    const studio = getStudio().map(r => {
      const a = ovStudioAcct(r);
      return {
        snapshot_date: date,
        rooftop_id: String(r[S_COL.rid] || ''),
        enterprise_id: r[S_COL.eid] || null, enterprise_name: r[S_COL.en] || null,
        rooftop_name: r[S_COL.rn] || null, csm: a.csm || null, segment: a.seg || null,
        region: a.region || null, account_type: a.type || null,
        arr: num(r[S_COL.arr]), mrr: num(r[S_COL.mrr]),
        usage_mtd: num(r[S_COL.u_mtd]), usage_may: num(r[S_COL.u_may]), pendency: num(r[S_COL.pen]),
        payment_rag: a.payment || null, ticket_rag: a.ticket || null, comm_rag: a.comm || null,
        usage_rag: a.usage || null, overall_rag: a.overall || null, red_components: a.redCount,
      };
    }).filter(x => x.rooftop_id);
    // ---- raw Vini contracts (per rooftop×agent, with computed RAGs) ----
    const vini = getVini().map(r => {
      const a = ovViniAcct(r);
      return {
        snapshot_date: date,
        rid: String(r.rid || ''), agent: String(r.agent || ''),
        enterprise_id: r.eid || null, enterprise_name: r.en || null, rooftop_name: r.rn || null,
        csm: a.csm || null, segment: a.seg || null, region: a.region || null, account_type: a.type || null,
        stage: r.stage || null, arr: num(r.arr), mrr: num(r.mrr), roi_mtd: num(r.roi_mtd),
        payment_rag: a.payment || null, ticket_rag: a.ticket || null, comm_rag: a.comm || null,
        overall_rag: a.overall || null, red_components: a.redCount,
      };
    }).filter(x => x.rid);
    // ---- churn events (CHURN_ANALYSIS) ----
    const CH = (typeof CHURN_ANALYSIS !== 'undefined' && Array.isArray(CHURN_ANALYSIS)) ? CHURN_ANALYSIS : [];
    const churn = CH.map((r, i) => ({
      snapshot_date: date, row_idx: i,
      enterprise_id: r.eid || null, customer: r.cust || null, segment: r.seg || null,
      product: r.prod || null, region: r.reg || null, csm: r.csm || null,
      arr: num(r.arr), churn_month: r.mon || null, category: r.cat || null,
      reason: r.rsn || null, billing: r.bill || null,
    }));
    // ---- computed metric totals per scope (UNFILTERED — default state) ----
    const ops = computeOvOps();
    const metrics = ['overall', 'studio', 'vini'].map(scope => {
      const o = computeOverview(scope);
      const S = ops.studio, V = ops.vini, O = ops.overall;
      const pk = (s, v, ov) => scope === 'studio' ? s : scope === 'vini' ? v : ov;
      const rs = pk(S.sRs, V.vRs, O.oRs) || {};
      const pay = pk(S.sPay, V.vPay, O.pay) || {};
      const sig = ops.sig ? pk(ops.sig.s, ops.sig.v, ops.sig.o) : null;
      return {
        snapshot_date: date, scope,
        rooftops: o.rooftopCount, live_arr: num(o.liveArr),
        new_addition: num(o.newArr), new_rooftops: o.newN,
        grr: o.grr != null ? +o.grr.toFixed(2) : null,
        churn_arr: num(o.churn.arr), churn_accounts: o.churn.n, contraction_arr: num(o.contraction.arr),
        green_n: o.bands.Green.n, green_arr: num(o.bands.Green.arr),
        amber_n: o.bands.Amber.n, amber_arr: num(o.bands.Amber.arr),
        red_n: o.bands.Red.n, red_arr: num(o.bands.Red.arr), na_n: o.bands.NA.n,
        agents: pk(null, V.vAgents, O.vAgents),
        report_sent_sent: rs.sent || 0, report_sent_attempted: rs.attempted || 0,
        report_sent_pct: rs.attempted ? +(rs.sent / rs.attempted * 100).toFixed(1) : null,
        payment_g: pay.Green || 0, payment_a: pay.Amber || 0, payment_r: pay.Red || 0,
        communication_pct: (() => { const c = pk(S.sIntPct, V.vIntPct, O.oIntPct); return c != null ? +c.toFixed(1) : null; })(),
        studio_usage: pk(num(S.sUProj), null, num(O.sUProj)),
        studio_usage_delta: pk(S.sUsageDelta != null ? +S.sUsageDelta.toFixed(1) : null, null, O.sUsageDelta != null ? +O.sUsageDelta.toFixed(1) : null),
        vini_roi: pk(null, V.vRoiMtd != null ? +V.vRoiMtd.toFixed(2) : null, O.vRoiMtd != null ? +O.vRoiMtd.toFixed(2) : null),
        vin_pendency: pk(num(S.sPen), null, num(O.sPen)),
        tickets_unresolved: pk((S.sTix && S.sTix.op) || 0, (V.vTix && V.vTix.op) || 0, O.oTixOpen || 0),
        arali_signals: sig != null ? sig : null,
      };
    });
    // ---- CSM action items (date × CSM, one column per segment) ----
    const csm_actions = [];
    const pushActions = (csmLabel, counts) => {
      const total = Object.keys(counts).reduce((s, k) => s + (counts[k] || 0), 0);
      csm_actions.push({ snapshot_date: date, csm: csmLabel, ...counts, total });
    };
    pushActions('__all__', csmActionCounts(null));
    (typeof csmReportRoster === 'function' ? csmReportRoster() : []).forEach(c => {
      try { pushActions(c, csmActionCounts(c)); } catch (e) {}
    });

    // ---- CSM scorecard tile metrics (date × CSM, one column per tile) ----
    const csm_metrics = [];
    const pushMetrics = (csmLabel, vals) => csm_metrics.push({ snapshot_date: date, csm: csmLabel, ...vals });
    pushMetrics('__all__', csmScorecardData(null));
    (typeof csmReportRoster === 'function' ? csmReportRoster() : []).forEach(c => {
      try { pushMetrics(c, csmScorecardData(c)); } catch (e) {}
    });

    return { studio, vini, churn, metrics, csm_actions, csm_metrics };
  }, today);
} finally {
  await browser.close();
  server.close();
}

console.log(`Snapshot ${today}: studio=${data.studio.length} vini=${data.vini.length} churn=${data.churn.length} metrics=${data.metrics.length} csm_actions=${data.csm_actions.length} csm_metrics=${data.csm_metrics.length}`);

if (!SUPA_KEY || !SUPA_URL) { console.log('SUPABASE_URL/SUPABASE_SERVICE_KEY not set — extracted only, no write (no-op).'); process.exit(0); }

// 2) Upsert into Supabase (batched, idempotent on the table PK).
async function upsert(table, rows, onConflict) {
  if (!rows.length) return;
  const B = 500;
  // Self-heal on schema drift: if the payload carries a column the table doesn't
  // have yet (PostgREST PGRST204), drop that column and retry rather than failing
  // the whole table. Keeps the snapshot alive when a new action-item segment
  // (e.g. image_pendency) is added to the UI before the DB column exists — the
  // `total` field still reflects it, so the trend stays accurate.
  const stripped = new Set();
  const applyStrip = arr => stripped.size ? arr.map(r => { const c = { ...r }; stripped.forEach(k => delete c[k]); return c; }) : arr;
  for (let i = 0; i < rows.length; i += B) {
    let batch = applyStrip(rows.slice(i, i + B));
    for (let attempt = 0; attempt < 16; attempt++) {
      const res = await fetch(`${SUPA_URL}/rest/v1/${table}?on_conflict=${onConflict}`, {
        method: 'POST',
        headers: {
          apikey: SUPA_KEY, Authorization: `Bearer ${SUPA_KEY}`,
          'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal',
        },
        body: JSON.stringify(batch),
      });
      if (res.ok) break;
      const txt = await res.text();
      const miss = txt.match(/Could not find the '([^']+)' column/);
      if (miss && !stripped.has(miss[1])) { stripped.add(miss[1]); batch = applyStrip(batch); continue; }
      throw new Error(`${table} upsert failed (${res.status}): ${txt.slice(0, 300)}`);
    }
  }
  const note = stripped.size ? ` (dropped unknown col(s): ${[...stripped].join(', ')} — add them in Supabase to store the breakdown)` : '';
  console.log(`  ${table}: upserted ${rows.length}${note}`);
}

// Same-day re-runs first clear that day's rows so deletions/renames don't linger.
async function clearDay(table) {
  await fetch(`${SUPA_URL}/rest/v1/${table}?snapshot_date=eq.${today}`, {
    method: 'DELETE', headers: { apikey: SUPA_KEY, Authorization: `Bearer ${SUPA_KEY}`, Prefer: 'return=minimal' },
  });
}
// Each table saves independently — a missing/locked table is logged and skipped
// so it never blocks the others (resilient save).
const targets = [
  ['studio_snapshots',      data.studio,      'snapshot_date,rooftop_id'],
  ['vini_snapshots',        data.vini,        'snapshot_date,rid,agent'],
  ['churn_snapshots',       data.churn,       'snapshot_date,row_idx'],
  ['metric_snapshots',      data.metrics,     'snapshot_date,scope'],
  ['csm_action_snapshots',  data.csm_actions, 'snapshot_date,csm'],
  ['csm_metric_snapshots',  data.csm_metrics, 'snapshot_date,csm'],
];
const failures = [];
for (const [t] of targets) { try { await clearDay(t); } catch (e) {} }
for (const [t, rows, oc] of targets) {
  try { await upsert(t, rows, oc); }
  catch (e) { failures.push(t); console.error(`  ${t}: SKIPPED — ${String(e.message).slice(0, 180)}`); }
}
if (failures.length) {
  console.error(`Snapshot saved ${targets.length - failures.length}/${targets.length} tables for ${today}. Missing: ${failures.join(', ')} (create them in Supabase).`);
  process.exit(1);
}
console.log(`Supabase snapshot complete for ${today}.`);
process.exit(0);
