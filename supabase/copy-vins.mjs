#!/usr/bin/env node
// Periodic copy of the external `vins` table into the CSM Supabase project, so it
// can be queried from the web SQL Editor. Mirrors the source each run
// (drop → recreate with the source schema → reload all rows). NOT live.
//
// Env (GitHub Actions secrets):
//   VINS_SOURCE_DB_URL — Postgres connection string of the SOURCE vins database
//   CSM_DEST_DB_URL    — Postgres connection string of the CSM project (DESTINATION)
// Both must allow normal SQL (use the Session pooler :5432 or Direct connection,
// NOT the transaction pooler :6543).
import pg from 'pg';
const { Client } = pg;

const SRC = process.env.VINS_SOURCE_DB_URL;
const DST = process.env.CSM_DEST_DB_URL;
const SCHEMA = 'public';
const TABLE = 'vins';

if (!SRC || !DST) { console.log('VINS_SOURCE_DB_URL / CSM_DEST_DB_URL not set — skipping (no-op).'); process.exit(0); }

const ident = s => '"' + String(s).replace(/"/g, '""') + '"';
const src = new Client({ connectionString: SRC, ssl: { rejectUnauthorized: false } });
const dst = new Client({ connectionString: DST, ssl: { rejectUnauthorized: false } });

// Diagnostics — confirm each URL parses to the right host/user/db and that a
// password is actually present (length only — never the value).
function diag(label, url) {
  try {
    const u = new URL(url);
    console.log(`${label}: host=${u.hostname} port=${u.port || '(none)'} user=${decodeURIComponent(u.username)} db=${u.pathname.slice(1) || '(none)'} passwordLength=${u.password.length}`);
    if (u.hostname.includes('...') || u.password.length === 0) console.log(`  ^ ${label} looks INVALID (placeholder host or empty password)`);
  } catch (e) { console.log(`${label}: UNPARSEABLE connection string (${e.message})`); }
}
diag('source(VINS_SOURCE_DB_URL)', SRC);
diag('dest(CSM_DEST_DB_URL)', DST);

try {
  try { await src.connect(); console.log('✓ source connected'); }
  catch (e) { console.error('✗ SOURCE connect failed:', e.message); throw e; }
  try { await dst.connect(); console.log('✓ dest connected'); }
  catch (e) { console.error('✗ DEST connect failed:', e.message); throw e; }

  // 1) Source column definitions (preserve types; fall back to text for exotic ones).
  const colsRes = await src.query(
    `select column_name, data_type, udt_name
       from information_schema.columns
      where table_schema=$1 and table_name=$2
      order by ordinal_position`, [SCHEMA, TABLE]);
  if (!colsRes.rows.length) throw new Error(`source table ${SCHEMA}.${TABLE} not found (no columns)`);
  const cols = colsRes.rows.map(c => {
    let type;
    if (c.data_type === 'ARRAY') type = c.udt_name.replace(/^_/, '') + '[]';
    else if (c.data_type === 'USER-DEFINED') type = 'text';     // enums → text
    else type = c.data_type;                                    // integer/text/numeric/timestamptz/...
    return { name: c.column_name, type };
  });
  const colNames = cols.map(c => c.name);

  // 2) All source rows.
  const rows = (await src.query(`select * from ${ident(SCHEMA)}.${ident(TABLE)}`)).rows;

  // 3) Recreate the destination table to mirror the source schema.
  const ddl = `drop table if exists ${ident(SCHEMA)}.${ident(TABLE)} cascade;\n`
    + `create table ${ident(SCHEMA)}.${ident(TABLE)} (\n  `
    + cols.map(c => `${ident(c.name)} ${c.type}`).join(',\n  ') + `\n);`;
  await dst.query(ddl);

  // 4) Bulk insert in batches (stay under Postgres' 65535-parameter limit).
  const B = Math.max(1, Math.floor(50000 / Math.max(1, colNames.length)));
  for (let i = 0; i < rows.length; i += B) {
    const batch = rows.slice(i, i + B);
    const params = [];
    const tuples = batch.map(r => '(' + colNames.map(cn => { params.push(r[cn]); return '$' + params.length; }).join(',') + ')');
    await dst.query(`insert into ${ident(SCHEMA)}.${ident(TABLE)} (${colNames.map(ident).join(',')}) values ${tuples.join(',')}`, params);
  }
  // Read-only "360 Pending" aggregate per team_id, exposed to the anon role so
  // the dashboard can fetch it via REST (raw vins stays inaccessible to anon).
  await dst.query(`create or replace view ${ident(SCHEMA)}.vins_360_pending as
    select team_id, count(*)::int as pending
    from ${ident(SCHEMA)}.${ident(TABLE)}
    where output_processing_spin = 1 and status = 'Not Delivered'
      and spin_reason_bucket = 'Insufficient Images' and team_id is not null
    group by team_id`);
  await dst.query(`grant usage on schema ${ident(SCHEMA)} to anon`).catch(() => {});
  await dst.query(`grant select on ${ident(SCHEMA)}.vins_360_pending to anon`).catch(() => {});
  const v360 = (await dst.query(`select count(*)::int as teams, coalesce(sum(pending),0)::int as total from ${ident(SCHEMA)}.vins_360_pending`)).rows[0];
  // Let the REST/PostgREST schema cache pick up the new table + view.
  await dst.query(`notify pgrst, 'reload schema'`).catch(() => {});
  console.log(`vins copy complete: ${rows.length} rows × ${cols.length} cols → ${SCHEMA}.${TABLE}. 360 Pending: ${v360.total} across ${v360.teams} teams.`);
} finally {
  await src.end().catch(() => {});
  await dst.end().catch(() => {});
}
process.exit(0);
