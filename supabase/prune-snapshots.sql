-- One-time snapshot retention cleanup for the CSM Supabase project.
-- ---------------------------------------------------------------------------
-- WHY: the six *_snapshots tables had no retention and grew one generation per
-- day forever (vini_snapshots ~4 rows/rooftop/day), which exhausted the
-- project's disk/compute (2026-07-21 "exhausting multiple resources" banner).
-- The daily job (email/supabase-snapshot.mjs) now prunes to 90 days on every
-- run, but that only removes NEW overflow going forward. Run this ONCE, after
-- the DB is back online, to clear the accumulated backlog and reclaim disk.
--
-- WHEN: only after the project is reachable again (upgrade compute / restore
-- first). VACUUM FULL takes an exclusive lock per table and needs free disk to
-- rewrite — if disk is 100% full, delete first (Step 1), let autovacuum settle,
-- then run VACUUM FULL (Step 2). Run in the Supabase SQL editor.
--
-- WINDOW: keep the last 90 days. Change 90 below if you want a different window
-- (must match SNAPSHOT_RETENTION_DAYS in the workflow if you override it there).
-- ---------------------------------------------------------------------------

-- Step 0 (optional) — preview how many rows each table would drop.
select 'studio_snapshots'     as tbl, count(*) as rows_to_delete from studio_snapshots     where snapshot_date < current_date - interval '90 days'
union all select 'vini_snapshots',        count(*) from vini_snapshots        where snapshot_date < current_date - interval '90 days'
union all select 'churn_snapshots',       count(*) from churn_snapshots       where snapshot_date < current_date - interval '90 days'
union all select 'metric_snapshots',      count(*) from metric_snapshots      where snapshot_date < current_date - interval '90 days'
union all select 'csm_action_snapshots',  count(*) from csm_action_snapshots  where snapshot_date < current_date - interval '90 days'
union all select 'csm_metric_snapshots',  count(*) from csm_metric_snapshots  where snapshot_date < current_date - interval '90 days';

-- Step 1 — delete rows older than the retention window.
delete from studio_snapshots     where snapshot_date < current_date - interval '90 days';
delete from vini_snapshots        where snapshot_date < current_date - interval '90 days';
delete from churn_snapshots       where snapshot_date < current_date - interval '90 days';
delete from metric_snapshots      where snapshot_date < current_date - interval '90 days';
delete from csm_action_snapshots  where snapshot_date < current_date - interval '90 days';
delete from csm_metric_snapshots  where snapshot_date < current_date - interval '90 days';

-- Step 2 — reclaim disk and refresh planner stats. VACUUM FULL rewrites the
-- table to physically return space to the OS (plain autovacuum only marks it
-- reusable). Run these one at a time if disk is very tight.
vacuum full analyze studio_snapshots;
vacuum full analyze vini_snapshots;
vacuum full analyze churn_snapshots;
vacuum full analyze metric_snapshots;
vacuum full analyze csm_action_snapshots;
vacuum full analyze csm_metric_snapshots;
