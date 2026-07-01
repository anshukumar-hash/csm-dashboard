-- Day-level historical snapshot tables for the CSM dashboard.
-- Run once in Supabase → SQL Editor (project iglxkivlamzyshidbakm).
-- The daily job upserts on the primary keys, so re-runs overwrite the same day.

-- Per-rooftop Studio snapshot (one row per rooftop per day)
create table if not exists studio_snapshots (
  snapshot_date   date not null,
  rooftop_id      text not null,
  enterprise_id   text,
  enterprise_name text,
  rooftop_name    text,
  csm             text,
  segment         text,
  region          text,
  account_type    text,
  arr             numeric,
  mrr             numeric,
  usage_mtd       numeric,
  usage_may       numeric,
  pendency        numeric,
  payment_rag     text,
  ticket_rag      text,
  comm_rag        text,
  usage_rag       text,
  overall_rag     text,
  red_components  int,
  primary key (snapshot_date, rooftop_id)
);

-- Per rooftop×agent Vini snapshot
create table if not exists vini_snapshots (
  snapshot_date   date not null,
  rid             text not null,
  agent           text not null,
  enterprise_id   text,
  enterprise_name text,
  rooftop_name    text,
  csm             text,
  segment         text,
  region          text,
  account_type    text,
  stage           text,
  arr             numeric,
  mrr             numeric,
  roi_mtd         numeric,
  payment_rag     text,
  ticket_rag      text,
  comm_rag        text,
  overall_rag     text,
  red_components  int,
  primary key (snapshot_date, rid, agent)
);

-- Churn / contraction events (CHURN_ANALYSIS) snapshot
create table if not exists churn_snapshots (
  snapshot_date date not null,
  row_idx       int  not null,
  enterprise_id text,
  customer      text,
  segment       text,
  product       text,
  region        text,
  csm           text,
  arr           numeric,
  churn_month   text,
  category      text,
  reason        text,
  billing       text,
  primary key (snapshot_date, row_idx)
);

-- Computed aggregate metrics per scope (overall / studio / vini)
create table if not exists metric_snapshots (
  snapshot_date         date not null,
  scope                 text not null,
  rooftops              int,
  live_arr              numeric,
  new_addition          numeric,
  new_rooftops          int,
  grr                   numeric,
  churn_arr             numeric,
  churn_accounts        int,
  contraction_arr       numeric,
  green_n int, green_arr numeric,
  amber_n int, amber_arr numeric,
  red_n   int, red_arr   numeric,
  na_n    int,
  agents                int,
  report_sent_sent      int,
  report_sent_attempted int,
  report_sent_pct       numeric,
  payment_g int, payment_a int, payment_r int,
  communication_pct     numeric,
  studio_usage          numeric,
  studio_usage_delta    numeric,
  vini_roi              numeric,
  vin_pendency          numeric,
  tickets_unresolved    int,
  arali_signals         int,
  primary key (snapshot_date, scope)
);

-- CSM action items (date × CSM → one column per segment).
-- csm = '__all__' is the whole-book row. Wide format: each segment is a column.
create table if not exists csm_action_snapshots (
  snapshot_date    date not null,
  csm              text not null,
  health           int,
  account          int,
  report           int,
  payment          int,
  communication    int,
  usage_studio     int,
  feature_adoption int,
  pendency_360     int,
  usage_vini       int,
  signals          int,
  tickets          int,
  total            int,
  primary key (snapshot_date, csm)
);

-- CSM scorecard tile metrics (date × CSM → one column per header card).
-- csm = '__all__' is the whole-book row. new_addition / nrr are org-only (null per CSM).
create table if not exists csm_metric_snapshots (
  snapshot_date         date not null,
  csm                   text not null,
  live_arr              numeric,
  rooftops              int,
  enterprises           int,
  new_addition          numeric,
  churn_arr             numeric,
  churn_accounts        int,
  comm_pct              numeric,
  report_sent_sent      int,
  report_sent_attempted int,
  report_sent_pct       numeric,
  studio_usage          numeric,
  tickets_unresolved    int,
  payment_green         int,
  payment_amber         int,
  payment_red           int,
  payment_green_pct     numeric,
  vin_pendency          numeric,
  grr                   numeric,
  nrr                   numeric,
  vini_roi              numeric,
  arali_open_signals    int,
  primary key (snapshot_date, csm)
);

-- Handy trend indexes
create index if not exists idx_studio_snap_date  on studio_snapshots(snapshot_date);
create index if not exists idx_vini_snap_date    on vini_snapshots(snapshot_date);
create index if not exists idx_churn_snap_date   on churn_snapshots(snapshot_date);
create index if not exists idx_metric_snap_scope on metric_snapshots(scope, snapshot_date);
create index if not exists idx_csmact_csm        on csm_action_snapshots(csm, snapshot_date);
create index if not exists idx_csmmet_csm        on csm_metric_snapshots(csm, snapshot_date);
