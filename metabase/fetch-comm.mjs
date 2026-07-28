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

// Long-lived, READ-ONLY pre-signed embed token for question 358 (issued
// 2026-07-17, exp 2028-07-16). Same class of public read token as the Arali
// Q426 signals token already embedded in the page. Env METABASE_COMM_TOKEN
// overrides; if a signing SECRET is provided we mint a fresh short-lived token
// instead (preferred once the embedding secret is rotated).
const COMM_TOKEN_DEFAULT = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyZXNvdXJjZSI6eyJxdWVzdGlvbiI6MzU4fSwicGFyYW1zIjp7fSwiZXhwIjoxODQ3MzUxODAyLCJpYXQiOjE3ODQyNzk4MDF9.th8bDn6aoYRzVonZD7S8kutohgCKIzTOMOXrRNNSigw';

// ---- 1) obtain the embed JWT: mint from SECRET if present, else use the token ----
const b64url = buf => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
let token;
if (SECRET) {
  const now = Math.floor(Date.now() / 1000);
  const signingInput = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' })) + '.'
    + b64url(JSON.stringify({ resource: { question: QUESTION }, params: {}, iat: now, exp: now + 600, _embedding_params: {} }));
  token = signingInput + '.' + b64url(crypto.createHmac('sha256', SECRET).update(signingInput).digest());
} else {
  token = (process.env.METABASE_COMM_TOKEN || COMM_TOKEN_DEFAULT).trim();
  if (!token) { console.error('ERROR: no METABASE_SECRET_KEY to mint and no METABASE_COMM_TOKEN / embedded token.'); process.exit(1); }
}

// ---- 2) query the embed endpoint (/query/json → array of row OBJECTS; unlike
// /query it is NOT capped at the 2000-row display limit, so we get the full
// history) ----
const url = `${BASE}/api/embed/card/${token}/query/json`;
const resp = await fetch(url, { headers: { Accept: 'application/json' } });
if (!resp.ok) {
  const body = await resp.text().catch(() => '');
  console.error(`ERROR: Metabase ${resp.status} — ${body.slice(0, 300)}`);
  process.exit(1);
}
const rows = await resp.json();
if (!Array.isArray(rows) || !rows.length) { console.error('ERROR: empty/non-array response from question ' + QUESTION); process.exit(1); }
const keys = Object.keys(rows[0]);
console.log(`Fetched question ${QUESTION}: ${rows.length} rows`);
console.log('Columns:', keys.join('  |  '));

// ---- 3) auto-detect the fields we need (by object key) ----
const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
const findKey = (...patterns) => {
  for (const p of patterns) { const k = keys.find(k => p.test(norm(k))); if (k) return k; }
  return null;
};
const kEid  = findKey(/companyexternalid|externalid/, /^enterpriseid$/, /enterpriseid/, /companyid/, /^entid$/);
const kName = findKey(/companyname/, /^enterprisename$/, /enterprisename/, /^enterprise$/, /^account(name)?$/);
const kAvg  = findKey(/averagecsatscore/, /avgcsat/, /csatscore/, /^averagecsat$/, /^avg$/, /^csat$/, /^score$/);
const kInt  = findKey(/interactioncount/, /interactions?/, /^intcount$/, /engagement/);
const kDate = findKey(/^date$/, /date/, /snapshot|createdat|day/);
console.log(`Detected → eid:[${kEid}] name:[${kName}] avg:[${kAvg}] int:[${kInt}] date:[${kDate}]`);
if (!kAvg || (!kEid && !kName)) {
  console.error('ERROR: could not locate a CSAT score field and an enterprise id/name field for question ' + QUESTION + '.');
  process.exit(1);
}

// ---- 4) transform → the 4 CSAT dicts ----
const todayISO = new Date().toISOString().slice(0, 10);
const normCsatName = s => { let t = String(s || ''); const d = t.indexOf(' - '); if (d >= 0) t = t.slice(0, d); return t.trim().toLowerCase(); };
const ragOf = avg => avg == null ? 'NA' : (avg < 2.5 ? 'Red' : (avg < 4 ? 'Amber' : 'Green'));
const toNum = v => { if (v == null || v === '') return null; const n = parseFloat(String(v).replace(/[^0-9.\-]/g, '')); return isNaN(n) ? null : n; };

const by_eid = {}, by_name = {}, all_by_eid = {}, all_by_name = {};
for (const row of rows) {
  const eid  = kEid  ? String(row[kEid]  ?? '').trim() : '';
  const name = kName ? String(row[kName] ?? '').trim() : '';
  const avg  = kAvg  ? toNum(row[kAvg]) : null;
  const iso  = (kDate ? String(row[kDate] ?? '').trim().slice(0, 10) : '') || todayISO;
  const intC = kInt  ? (toNum(row[kInt]) || 0) : 0;
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
