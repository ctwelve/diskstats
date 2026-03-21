-- diskstats built-in analytics materialized views
--
-- This script extends the existing public analytics surface with heavyweight,
-- precomputed query objects to match dataset scale.

SET search_path = public, bb;

-- Keep names harmonized with existing materialized analytics objects in schema.sql.
DROP MATERIALIZED VIEW IF EXISTS public.model_fleet_latest_stats;
DROP MATERIALIZED VIEW IF EXISTS public.model_reliability_90d;
DROP MATERIALIZED VIEW IF EXISTS public.model_smart_signals_30d;
DROP MATERIALIZED VIEW IF EXISTS public.model_lifetime_leaderboard;

-- 1) Latest fleet composition by model on the most recent observed day.
CREATE MATERIALIZED VIEW public.model_fleet_latest_stats AS
WITH latest_day AS (
  SELECT max(date) AS as_of_date
  FROM public.drive_day
)
SELECT
  ld.as_of_date,
  p.name AS provider,
  d.model_id,
  m.model_name,
  m.media_type,
  m.nominal_capacity_bytes,
  count(*) AS active_drives,
  count(*) FILTER (WHERE dd.failed) AS failed_on_day,
  round(
    100.0 * count(*) FILTER (WHERE dd.failed)::numeric
      / NULLIF(count(*)::numeric, 0),
    4
  ) AS failed_pct_on_day
FROM latest_day ld
JOIN public.drive_day dd ON dd.date = ld.as_of_date
JOIN public.drive d ON d.drive_id = dd.drive_id
JOIN public.drive_model m ON m.model_id = d.model_id
JOIN public.provider p ON p.provider_id = dd.provider_id
GROUP BY ld.as_of_date, p.name, d.model_id, m.model_name, m.media_type, m.nominal_capacity_bytes
WITH NO DATA;

-- 2) Rolling 90-day model reliability summary.
CREATE MATERIALIZED VIEW public.model_reliability_90d AS
WITH windowed AS (
  SELECT
    dd.provider_id,
    d.model_id,
    dd.drive_id,
    dd.failed
  FROM public.drive_day dd
  JOIN public.drive d ON d.drive_id = dd.drive_id
  WHERE dd.date >= (CURRENT_DATE - INTERVAL '90 days')
)
SELECT
  p.name AS provider,
  w.model_id,
  m.model_name,
  count(DISTINCT w.drive_id) AS drives_seen,
  count(*) AS drive_days,
  count(*) FILTER (WHERE w.failed) AS failures,
  round(
    365.0 * count(*) FILTER (WHERE w.failed)::numeric
      / NULLIF(count(*)::numeric, 0),
    6
  ) AS annualized_failures_per_drive_year
FROM windowed w
JOIN public.provider p ON p.provider_id = w.provider_id
JOIN public.drive_model m ON m.model_id = w.model_id
GROUP BY p.name, w.model_id, m.model_name
WITH NO DATA;

-- 3) SMART-signal prevalence and same-day failure co-occurrence, trailing 30 days.
CREATE MATERIALIZED VIEW public.model_smart_signals_30d AS
WITH windowed AS (
  SELECT
    dd.provider_id,
    d.model_id,
    dd.failed,
    (coalesce(dd.smart_5_raw, 0) > 0) AS has_realloc,
    (coalesce(dd.smart_197_raw, 0) > 0) AS has_pending,
    (coalesce(dd.smart_198_raw, 0) > 0) AS has_offline_unc
  FROM public.drive_day dd
  JOIN public.drive d ON d.drive_id = dd.drive_id
  WHERE dd.date >= (CURRENT_DATE - INTERVAL '30 days')
)
SELECT
  p.name AS provider,
  w.model_id,
  m.model_name,
  count(*) AS drive_days,
  round(avg(has_realloc::int)::numeric, 6) AS realloc_day_rate,
  round(avg(has_pending::int)::numeric, 6) AS pending_day_rate,
  round(avg(has_offline_unc::int)::numeric, 6) AS offline_unc_day_rate,
  round(avg(failed::int)::numeric, 6) AS fail_day_rate,
  round(avg((failed AND has_pending)::int)::numeric, 6) AS fail_and_pending_rate
FROM windowed w
JOIN public.provider p ON p.provider_id = w.provider_id
JOIN public.drive_model m ON m.model_id = w.model_id
GROUP BY p.name, w.model_id, m.model_name
WITH NO DATA;

-- 4) Lifetime leaderboard with exposure threshold, using existing lifetime aggregate.
CREATE MATERIALIZED VIEW public.model_lifetime_leaderboard AS
WITH provider_model_map AS (
  SELECT DISTINCT provider_id, model_id
  FROM public.drive
)
SELECT
  p.name AS provider,
  dm.model_id,
  mls.model_name,
  mls.drives_seen,
  mls.drive_days,
  mls.failures,
  mls.failures_per_drive_year AS annualized_failures_per_drive_year,
  mls.median_poh_at_fail,
  mls.realloc_day_rate,
  mls.pending_day_rate,
  mls.offline_unc_day_rate
FROM public.model_lifetime_stats mls
JOIN public.drive_model dm ON dm.model_name = mls.model_name
JOIN provider_model_map pmm ON pmm.model_id = dm.model_id
JOIN public.provider p ON p.provider_id = pmm.provider_id
WHERE mls.drive_days >= 10000
WITH NO DATA;

CREATE INDEX model_fleet_latest_stats_model_idx
  ON public.model_fleet_latest_stats (provider, model_name);
CREATE INDEX model_reliability_90d_rate_idx
  ON public.model_reliability_90d (annualized_failures_per_drive_year DESC);
CREATE INDEX model_smart_signals_30d_fail_pending_idx
  ON public.model_smart_signals_30d (fail_and_pending_rate DESC);
CREATE INDEX model_lifetime_leaderboard_rate_idx
  ON public.model_lifetime_leaderboard (annualized_failures_per_drive_year DESC);

-- Refresh helper for the full harmonized analytics collection in public schema.
CREATE OR REPLACE PROCEDURE public.refresh_analytics_materialized_views()
LANGUAGE plpgsql
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW public.drive_day_growth;
  REFRESH MATERIALIZED VIEW public.drive_lifecycle;
  REFRESH MATERIALIZED VIEW public.model_hazard_5k;
  REFRESH MATERIALIZED VIEW public.model_lifetime_stats;
  REFRESH MATERIALIZED VIEW public.model_quarter_stats;

  REFRESH MATERIALIZED VIEW public.model_fleet_latest_stats;
  REFRESH MATERIALIZED VIEW public.model_reliability_90d;
  REFRESH MATERIALIZED VIEW public.model_smart_signals_30d;
  REFRESH MATERIALIZED VIEW public.model_lifetime_leaderboard;
END;
$$;

COMMENT ON MATERIALIZED VIEW public.model_fleet_latest_stats IS
  'Latest-day fleet composition by provider/model, including same-day failure share.';
COMMENT ON MATERIALIZED VIEW public.model_reliability_90d IS
  'Trailing 90-day reliability summary per provider/model.';
COMMENT ON MATERIALIZED VIEW public.model_smart_signals_30d IS
  'Trailing 30-day SMART signal prevalence and failure co-occurrence per provider/model.';
COMMENT ON MATERIALIZED VIEW public.model_lifetime_leaderboard IS
  'Lifetime reliability leaderboard per provider/model with a 10,000 drive-day minimum.';
COMMENT ON PROCEDURE public.refresh_analytics_materialized_views() IS
  'Refreshes the harmonized analytics materialized views in public schema.';
