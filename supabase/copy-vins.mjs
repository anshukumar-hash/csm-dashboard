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

  // This is a bulk mirror job (large `select *` on the source + big batched
  // INSERTs on the dest). Supabase applies a short per-statement statement_timeout
  // by default, which was killing the vins INSERT batches once the table grew
  // (error 57014 "canceling statement due to statement timeout") — leaving the
  // freshly-dropped dest table empty and aborting every downstream JSON feed.
  // Lift the timeout for this session on BOTH ends (session pooler :5432 keeps it).
  await src.query(`set statement_timeout = '1200s'`).catch(e => console.log('  (src statement_timeout not set:', e.message + ')'));
  await dst.query(`set statement_timeout = '1200s'`).catch(e => console.log('  (dst statement_timeout not set:', e.message + ')'));

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

  // Per-rooftop spin_reason_bucket breakdown (360 Pendency detail) -> vins_buckets.json
  if (colNames.includes('spin_reason_bucket') && colNames.includes('rooftop_id')) {
    const br = (await dst.query(`
      select rooftop_id, max(enterprise_id) as enterprise_id,
        count(*) filter (where spin_reason_bucket='Insufficient Images') as ii,
        count(*) filter (where spin_reason_bucket='QC Hold')            as qch,
        count(*) filter (where spin_reason_bucket='QC Pending')         as qcp,
        count(*) filter (where spin_reason_bucket='Processing Pending') as pp,
        count(*) filter (where spin_reason_bucket='Upload Pending')     as up,
        count(*) filter (where spin_reason_bucket='Sold')              as sold,
        count(*) filter (where spin_reason_bucket='Others')            as inf,
        count(*) as total
      from public.vins
      where output_processing_spin=1 and spin_status='Not Delivered' and rooftop_id is not null
      group by rooftop_id`)).rows;
    const bmap = {};
    br.forEach(r => { bmap[String(r.rooftop_id)] = { e: r.enterprise_id, ii:+r.ii, qch:+r.qch, qcp:+r.qcp, pp:+r.pp, up:+r.up, sold:+r.sold, inf:+r.inf, total:+r.total }; });
    for (const p of [path.join(REPO, 'vins_buckets.json'), path.join(REPO, 'vercel_deploy', 'vins_buckets.json')]) fs.writeFileSync(p, JSON.stringify(bmap));
    console.log(`  wrote vins_buckets.json: ${Object.keys(bmap).length} rooftops`);
    // Per-VIN detail (for the modal CSV download): r=rooftop_id e=enterprise_id
    // d=dealer_vin_id v=vin b=bucketKey. Not-Delivered spins only.
    const dr = (await dst.query(`
      select rooftop_id as r, enterprise_id as e, dealer_vin_id as d, vin as v,
        case spin_reason_bucket
          when 'Insufficient Images' then 'ii' when 'QC Hold' then 'qch' when 'QC Pending' then 'qcp'
          when 'Processing Pending' then 'pp' when 'Upload Pending' then 'up' when 'Sold' then 'sold'
          when 'Others' then 'inf' else 'other' end as b
      from public.vins
      where output_processing_spin=1 and spin_status='Not Delivered' and rooftop_id is not null`)).rows;
    for (const p of [path.join(REPO, 'vins_360_detail.json'), path.join(REPO, 'vercel_deploy', 'vins_360_detail.json')]) fs.writeFileSync(p, JSON.stringify(dr));
    console.log(`  wrote vins_360_detail.json: ${dr.length} VIN rows`);
  }

  // Image Pendency (CATALOG) — per-rooftop reason_bucket breakdown + per-VIN detail.
  // Filter: output_processing_catalog=1 AND status='Not Delivered' AND has_photos=1.
  // Same shape/keys as the spin 360 feeds, published to vins_image_*.json.
  if (['reason_bucket', 'rooftop_id', 'output_processing_catalog', 'status', 'has_photos'].every(c => colNames.includes(c))) {
    const ib = (await dst.query(`
      select rooftop_id, max(enterprise_id) as enterprise_id,
        count(*) filter (where reason_bucket='Missing VIN Name')    as mvn,
        count(*) filter (where reason_bucket='Processing Pending')  as pp,
        count(*) filter (where reason_bucket='QC Pending')          as qcp,
        count(*) filter (where reason_bucket='QC Hold')             as qch,
        count(*) filter (where reason_bucket='Scheduled Push')      as sp,
        count(*) filter (where reason_bucket='Sold')                as sold,
        count(*) filter (where reason_bucket='Upload Pending')      as up,
        count(*) filter (where reason_bucket='Others')              as inf,
        count(*) as total
      from public.vins
      where output_processing_catalog=1 and status='Not Delivered' and has_photos=1 and rooftop_id is not null
      group by rooftop_id`)).rows;
    const imap = {};
    ib.forEach(r => { imap[String(r.rooftop_id)] = { e: r.enterprise_id, mvn:+r.mvn, pp:+r.pp, qcp:+r.qcp, qch:+r.qch, sp:+r.sp, sold:+r.sold, up:+r.up, inf:+r.inf, total:+r.total }; });
    for (const p of [path.join(REPO, 'vins_image_buckets.json'), path.join(REPO, 'vercel_deploy', 'vins_image_buckets.json')]) fs.writeFileSync(p, JSON.stringify(imap));
    console.log(`  wrote vins_image_buckets.json: ${Object.keys(imap).length} rooftops`);
    const idr = (await dst.query(`
      select rooftop_id as r, enterprise_id as e, dealer_vin_id as d, vin as v,
        case reason_bucket
          when 'Missing VIN Name' then 'mvn' when 'Processing Pending' then 'pp' when 'QC Pending' then 'qcp'
          when 'QC Hold' then 'qch' when 'Scheduled Push' then 'sp' when 'Sold' then 'sold'
          when 'Upload Pending' then 'up' when 'Others' then 'inf' else 'other' end as b
      from public.vins
      where output_processing_catalog=1 and status='Not Delivered' and has_photos=1 and rooftop_id is not null`)).rows;
    for (const p of [path.join(REPO, 'vins_image_detail.json'), path.join(REPO, 'vercel_deploy', 'vins_image_detail.json')]) fs.writeFileSync(p, JSON.stringify(idr));
    console.log(`  wrote vins_image_detail.json: ${idr.length} VIN rows`);
  } else {
    console.log('  Image Pendency SKIPPED (missing catalog/status/has_photos/reason_bucket cols).');
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
    // Per-rooftop feature-adoption map -> rooftop_adoption.json for the dashboard.
    console.log('  rooftop_adoption sample:', JSON.stringify((await dst.query(`select team_id, app_adoption, smartview_vdp_enabled, smartview_vlp_enabled, smart_campaign_adoption, active from public.rooftop_adoption limit 3`)).rows));
    const truthy = v => { if (v === true || v === 1) return true; const s = String(v == null ? '' : v).trim().toLowerCase(); return ['true','t','yes','y','1','enabled','adopted','live','active','on'].includes(s); };
    const ad = (await dst.query(`select * from public.rooftop_adoption where team_id is not null`)).rows;
    const amap = {};
    ad.forEach(r => { amap[String(r.team_id)] = { n: r.team_name, en: r.enterprise_name, e: r.enterprise_id, app: truthy(r.app_adoption), vdp: truthy(r.smartview_vdp_enabled), vlp: truthy(r.smartview_vlp_enabled), camp: truthy(r.smart_campaign_adoption), active: truthy(r.active) }; });
    for (const p of [path.join(REPO, 'rooftop_adoption.json'), path.join(REPO, 'vercel_deploy', 'rooftop_adoption.json')]) fs.writeFileSync(p, JSON.stringify(amap));
    console.log(`  wrote rooftop_adoption.json: ${Object.keys(amap).length} rooftops`);
  } else {
    console.log('  Rooftop_adoption: no matching table found in source.');
  }

  // ---- 3) CSM action-item 7-day trend (from csm_action_snapshots) ----
  // -> csm_action_trend.json { csm: [{d:'YYYY-MM-DD', t:total}, ...] }
  try {
    const tr = (await dst.query(`
      select csm, snapshot_date::text as d, total,
        health, account, report, payment, communication, usage_studio,
        feature_adoption, image_pendency, pendency_360, usage_vini, signals, tickets
      from public.csm_action_snapshots
      where snapshot_date >= (current_date - interval '6 days')
      order by csm, snapshot_date`)).rows;
    const trend = {};
    tr.forEach(r => { (trend[r.csm] = trend[r.csm] || []).push({
      d: r.d, t: +r.total || 0,
      health:+r.health||0, account:+r.account||0, report:+r.report||0, payment:+r.payment||0,
      communication:+r.communication||0, usage_studio:+r.usage_studio||0, feature_adoption:+r.feature_adoption||0,
      image_pendency:+r.image_pendency||0, pendency_360:+r.pendency_360||0, usage_vini:+r.usage_vini||0, signals:+r.signals||0, tickets:+r.tickets||0 }); });
    for (const p of [path.join(REPO, 'csm_action_trend.json'), path.join(REPO, 'vercel_deploy', 'csm_action_trend.json')]) fs.writeFileSync(p, JSON.stringify(trend));
    console.log(`  wrote csm_action_trend.json: ${Object.keys(trend).length} CSMs`);
  } catch (e) { console.log('  csm_action_trend skipped:', String(e.message).slice(0, 140)); }

  await dst.query(`notify pgrst, 'reload schema'`).catch(() => {});
  console.log('copy complete.');
} finally {
  await src.end().catch(() => {});
  await dst.end().catch(() => {});
}
process.exit(0);
