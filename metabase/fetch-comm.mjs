#!/usr/bin/env node
// Fetch the Communication (CSAT) data from Metabase question 358 and publish it
// as comm_metabase.json — the runtime replacement for the Google-Sheet
// (gid 179502765) CSAT feed. The dashboard's fetchCommMetabase() swaps this into
// CSAT_BY_EID / CSAT_BY_NAME / CSAT_ALL_BY_EID / CSAT_ALL_BY_NAME on load.
//
// Static-embedding flow: mint a short-lived HS256 JWT signed with the Metabase
// embedding secret key, then GET /api/embed/card/{token}/query. The secret is
// NEVER stored in this public repo — it comes from the METABASE_EMBED_SECRET
// GitHub Actions secret at run time.
//
// Env:
//   METABASE_EMBED_SECRET  (required)  static-embedding secret key
//   METABASE_URL           default https://metabase.arali.ai
//   METABASE_COMM_QUESTION default 358
//
// RAG thresholds match sync.ps1 exactly: avg<2.5 Red, <4 Amber, >=4 Green, blank NA.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const SECRET   = (process.env.METABASE_SECRET_KEY || process.env.METABASE_EMBED_SECRET || '').trim();
const BASE     = (process.env.METABASE_URL || 'https://metabase.arali.ai').replace(/\/+$/, '');
const QUESTION = Number(process.env.METABASE_COMM_QUESTION || 358);

if (!SECRET) { console.error('ERROR: METABASE_SECRET_KEY (or METABASE_EMBED_SECRET) is not set.'); process.exit(1); }

// ---- 1) mint the signed embed JWT (HS256) ----
const b64url = buf => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const now = Math.floor(Date.now() / 1000);
const header  = { alg: 'HS256', typ: 'JWT' };
const payload = { resource: { question: QUESTION }, params: {}, iat: now, exp: now + 600, _embedding_params: {} };
const signingInput = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
const sig = crypto.createHmac('sha256', SECRET).update(signingInput).digest();
const token = signingInput + '.' + b64url(sig);

// ---- 2) query the embed endpoint ----
const url = `${BASE}/api/embed/card/${token}/query`;
const resp = await fetch(url, { headers: { Accept: 'application/json' } });
if (!resp.ok) {
  const body = await resp.text().catch(() => '');
  console.error(`ERROR: Metabase ${resp.status} — ${body.slice(0, 300)}`);
  process.exit(1);
}
const json = await resp.json();
const cols = (json?.data?.cols || []).map(c => c.display_name || c.name || '');
const rows = json?.data?.rows || [];
console.log(`Fetched question ${QUESTION}: ${rows.length} rows`);
console.log('Columns:', cols.map((c, i) => `[${i}] ${c}`).join('  |  '));

// ---- 3) auto-detect the columns we need ----
const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const findCol = (...patterns) => {
  for (const p of patterns) { const i = cols.findIndex(c => p.test(norm(c))); if (i >= 0) return i; }
  return -1;
};
const iEid  = findCol(/^enterpriseid$/, /enterpriseid/, /^entid$/, /companyid|companyexternalid|externalid/);
const iName = findCol(/^enterprisename$/, /enterprisename/, /companyname/, /^enterprise$/, /^account(name)?$/);
const iAvg  = findCol(/averagecsatscore/, /avgcsat/, /csatscore/, /^averagecsat$/, /^avg$/, /^csat$/, /^score$/);
const iInt  = findCol(/interactioncount/, /interactions?/, /^intcount$/, /engagement/);
const iDate = findCol(/^date$/, /date/, /snapshot|createdat|day/);
console.log(`Detected → eid:[${iEid}] name:[${iName}] avg:[${iAvg}] int:[${iInt}] date:[${iDate}]`);
if (iAvg < 0 || (iEid < 0 && iName < 0)) {
  console.error('ERROR: could not locate a CSAT score column and an enterprise id/name column. '
    + 'Adjust the findCol patterns in fetch-comm.mjs to match question ' + QUESTION + "'s schema.");
  process.exit(1);
}

// ---- 4) transform → the 4 CSAT dicts ----
const todayISO = new Date().toISOString().slice(0, 10);
const normCsatName = s => { let t = String(s || ''); const d = t.indexOf(' - '); if (d >= 0) t = t.slice(0, d); return t.trim().toLowerCase(); };
const ragOf = avg => avg == null ? 'NA' : (avg < 2.5 ? 'Red' : (avg < 4 ? 'Amber' : 'Green'));
const toNum = v => { if (v == null || v === '') return null; const n = parseFloat(String(v).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? null : n; };

const by_eid = {}, by_name = {}, all_by_eid = {}, all_by_name = {};
for (const row of rows) {
  const eid  = iEid  >= 0 ? String(row[iEid]  ?? '').trim() : '';
  const name = iName >= 0 ? String(row[iName] ?? '').trim() : '';
  const avg  = iAvg  >= 0 ? toNum(row[iAvg]) : null;
  const iso  = (iDate >= 0 ? String(row[iDate] ?? '').trim().slice(0, 10) : '') || todayISO;
  const intC = iInt  >= 0 ? (toNum(row[iInt]) || 0) : 0;
  const rag  = ragOf(avg);
  const rec  = { date_iso: iso, avg, name };
  const hist = { date_iso: iso, avg, rag, intCount: Math.round(intC) };

  // latest-wins by date for the point-in-time dicts
  const newer = (cur) => !cur || String(iso) >= String(cur.date_iso || '');
  if (eid)  { if (newer(by_eid[eid]))  by_eid[eid]  = rec;
              (all_by_eid[eid]  = all_by_eid[eid]  || []).push(hist); }
  if (name) { const KN = name.toUpperCase().trim(); if (newer(by_name[KN])) by_name[KN] = rec;
              const nn = normCsatName(name); (all_by_name[nn] = all_by_name[nn] || []).push(hist); }
}

const out = { by_eid, by_name, all_by_eid, all_by_name,
  _meta: { source: `metabase question ${QUESTION}`, rows: rows.length, generated: new Date().toISOString(),
           eids: Object.keys(by_eid).length, names: Object.keys(by_name).length } };

// ---- 5) write feed (repo root + vercel_deploy copy) ----
const repoRoot = path.resolve(process.cwd(), '..');
const text = JSON.stringify(out);
for (const p of [path.join(repoRoot, 'comm_metabase.json'), path.join(repoRoot, 'vercel_deploy', 'comm_metabase.json')]) {
  fs.writeFileSync(p, text);
  console.log('wrote', p, `(${text.length} bytes)`);
}
console.log(`Done: ${out._meta.eids} enterprises by id, ${out._meta.names} by name.`);
