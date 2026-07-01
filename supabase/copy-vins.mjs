#!/usr/bin/env node
// Periodic copy of external source tables into the CSM Supabase project so they
// can be queried from the web SQL Editor. Mirrors each table (drop → recreate →
// reload). NOT live. Copies:
//   • public.vins            -> public.vins            (+ vins_360_pending view + vins360.json)
//   • Adoption.Rooftop_adoption -> public.rooftop_adoption
//
// Env (GitHub Actions secrets):
//   VINS_SOURCE_DB_URL — Postgres connection string of the SOURCE database
//   CSM_DEST_DB_URL    — Postgres connection string of the CSM project (DESTINATION)
// Both must allow normal SQL (Session pooler :5432 or Direct, NOT :6543).
import pg from 'pg';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
const { Client } = pg;
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const SRC = process.env.VINS_SOURCE_DB_URL;
const DST = process.env.CSM_DEST_DB_URL;

if (!SRC || !DST) { console.log('VINS_SOURCE_DB_URL / CSM_DEST_DB_URL not set — skipping (no-op).'); process.exit(0); }

const ident = s => '"' + String(s).replace(/"/g, '""') + '"';
const src = new Client({ connectionString: SRC, ssl: { rejectUnauthorized: false } });
const dst = new Client({ connectionString: DST, ssl: { rejectUnauthorized: false } });

function diag(label, url) {
  try {
    const u = new URL(url);
    console.log(`${label}: host=${u.hostname} port=${u.port || '(none)'} user=${decodeURIComponent(u.username)} db=${u.pathname.slice(1) || '(none)'} passwordLength=${u.password.length}`);
    if (u.hostname.includes('...') || u.password.length === 0) console.log(`  ^ ${label} looks INVALID (placeholder host or empty password)`);
  } catch (e) { console.log(`${label}: UNPARSEABLE connection string (${e.message})`); }
}
diag('source(VINS_SOURCE_DB_URL)', SRC);
diag('dest(CSM_DEST_DB_URL)', DST);

// Mirror a source table into public.<dstTable> on the destination. Returns
// { colNames } or null if the source table isn't found.
async function mirrorTable(srcSchema, srcTable, dstTable) {
  const colsRes = await src.query(
    `select column_name, data_type, udt_name from information_schema.columns
      where table_schema=$1 and table_name=$2 order by ordinal_position`, [srcSchema, srcTable]);
  if (!colsRes.rows.length) { console.log(`  ${srcSchema}.${srcTable}: NOT FOUND — skipped`); return null; }
  const cols = colsRes.rows.map(c => {
    let type;
    if (c.data_type === 'ARRAY') type = c.udt_name.replace(/^_/, '') + '[]';
    else if (c.data_type === 'USER-DEFINED') type = 'text';
    else type = c.data_type;
    return { name: c.column_name, type };
  });
  const colNames = cols.map(c => c.name);
  const rows = (await src.query(`select * from ${ident(srcSchema)}.${ident(srcTable)}`)).rows;
  await dst.query(`drop table if exists public.${ident(dstTable)} cascade;\n`
    + `create table public.${ident(dstTable)} (\n  ` + cols.map(c => `${ident(c.name)} ${c.type}`).join(',\n  ') + `\n);`);
  const B = Math.max(1, Math.floor(50000 / Math.max(1, colNames.length)));
  for (let i = 0; i < rows.length; i += B) {
    const batch = rows.slice(i, i + B);
    const params = [];
    const tuples = batch.map(r => '(' + colNames.map(cn => { params.push(r[cn]); return '$' + params.length; }).join(',') + ')');
    await dst.query(`insert into public.${ident(dstTable)} (${colNames.map(ident).join(',')}) values ${tuples.join(',')}`, params);
  }
  console.log(`  mirrored ${srcSchema}.${srcTable} -> public.${dstTable}: ${rows.length} rows × ${cols.length} cols\n    columns: ${colNames.join(', ')}`);
  return { colNames };
}

try {
  try { await src.connect(); console.log('✓ source connected'); }
  catch (e) { console.error('✗ SOURCE connect failed:', e.message); throw e; }
  try { await dst.connect(); console.log('✓ dest connected'); }
  catch (e) { console.error('✗ DEST connect failed:', e.message); throw e; }

  // ---- 1) vins ----
  const v = await mirrorTable('public', 'vins', 'vins');
  const colNames = v ? v.colNames : [];
  const teamCol = ['team_id', 'rooftop_id', 'dealer_id', 'rid', 'store_id'].find(c => colNames.includes(c))
    || colNames.find(c => /team|rooftop|dealer|store/i.test(c)) || null;
  const filterCols = ['output_processing_spin', 'spin_status', 'spin_reason_bucket'];
  const missingFilters = filterCols.filter(c => !colNames.includes(c));
  console.log(`  rooftop-id column -> ${teamCol || '(none)'}; missing filter cols: ${missingFilters.join(', ') || 'none'}`);

  // Distinct spin_reason_bucket values (for the per-bucket pivot query).
  if (colNames.includes('spin_reason_bucket')) {
    const buckets = (await dst.query(`select distinct spin_reason_bucket from public.vins where spin_reason_bucket is not null order by 1`)).rows.map(r => r.spin_reason_bucket);
    console.log('  spin_reason_bucket values:', JSON.stringify(buckets));
  }

  // 360 Pendency view + vins360.json (spin_status='Not Delivered' · Insufficient Images).
  if (teamCol && !missingFilters.length) {
    await dst.query(`create or replace view public.vins_360_pending as
      select ${ident(teamCol)} as team_id, count(*)::int as pending
      from public.vins
      where output_processing_spin = 1 and spin_status = 'Not Delivered'
        and spin_reason_bucket = 'Insufficient Images' and ${ident(teamCol)} is not null
      group by ${ident(teamCol)}`);
    await dst.query(`grant usage on schema public to anon`).catch(() => {});
    await dst.query(`grant select on public.vins_360_pending to anon`).catch(() => {});
    const map360 = {};
    (await dst.query(`select team_id, pending from public.vins_360_pending`)).rows
      .forEach(r => { if (r.team_id != null) map360[String(r.team_id)] = Number(r.pending) || 0; });
    for (const p of [path.join(REPO, 'vins360.json'), path.join(REPO, 'vercel_deploy', 'vins360.json')]) fs.writeFileSync(p, JSON.stringify(map360));
    console.log(`  360 Pendency: ${Object.values(map360).reduce((a, b) => a + b, 0)} across ${Object.keys(map360).length} rooftops. Wrote vins360.json.`);
  } else {
    for (const p of [path.join(REPO, 'vins360.json'), path.join(REPO, 'vercel_deploy', 'vins360.json')]) { if (!fs.existsSync(p)) fs.writeFileSync(p, '{}'); }
    console.log(`  360 view SKIPPED (teamCol=${teamCol}, missing=${missingFilters.join(',') || 'none'}).`);
  }

  // ---- 2) Adoption.Rooftop_adoption ----
  // Discover the exact schema/table (case-sensitive in Postgres), then mirror it.
  const adoptFound = (await src.query(
    `select table_schema, table_name from information_schema.tables
      where lower(table_name) like '%rooftop%adoption%' or lower(table_schema) = 'adoption'
      order by table_schema, table_name`)).rows;
  console.log('  adoption candidates:', JSON.stringify(adoptFound));
  if (adoptFound.length) {
    const a = adoptFound.find(r => /rooftop/i.test(r.table_name)) || adoptFound[0];
    await mirrorTable(a.table_schema, a.table_name, 'rooftop_adoption');
    await dst.query(`grant select on public.rooftop_adoption to anon`).catch(() => {});
  } else {
    console.log('  Rooftop_adoption: no matching table found in source.');
  }

  await dst.query(`notify pgrst, 'reload schema'`).catch(() => {});
  console.log('copy complete.');
} finally {
  await src.end().catch(() => {});
  await dst.end().catch(() => {});
}
process.exit(0);
