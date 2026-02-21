--
-- diskstats canonical schema (hand-maintained)
--
-- Purpose:
--   1) Create the diskstats database and provider-specific schemas.
--   2) Define ingest/staging objects (bb.*) and normalized analytics objects (public.*).
--   3) Seed minimal reference data required by loaders and normalization procedures.
--
-- Notes:
--   - This file is the readable counterpart to schema-master.sql (raw pg_dump output).
--   - Run with psql as a superuser or a role that can CREATE DATABASE.
--   - Expected loader flow:
--       bin/bb_dl (or bin/bb_dl_legacy) -> bin/bb_load.py -> bb.load_drive_day_backfill(...)
--

--
-- DATABASE
-- Create the empty database with deterministic locale/template settings.
--

DROP DATABASE IF EXISTS diskstats;
CREATE DATABASE diskstats WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE_PROVIDER = libc LOCALE = 'en_US.utf8';
COMMENT ON DATABASE diskstats IS 'Disk stats from BackBlaze and possibly other providers down the road';
\connect diskstats


--
-- SCHEMAS
-- Each data provider has its own schemas. BackBlaze has bb.
-- Public schema is for normalized data.
--

CREATE SCHEMA bb;

--
-- NORMALIZATION HELPERS
-- Immutable text normalizers used by canonical model/manufacturer metadata.
--

CREATE FUNCTION public.normalize_identifier_text(p_input text) RETURNS text
    LANGUAGE sql
    IMMUTABLE
    RETURNS NULL ON NULL INPUT
    AS $$
      SELECT NULLIF(regexp_replace(lower(btrim(p_input)), '[^a-z0-9]+', '', 'g'), '');
    $$;


--
-- STORED PROCEDURES
-- Loading pipeline entry points from raw Backblaze rows into normalized fact tables.
--

CREATE PROCEDURE bb.load_drive_day_backfill(IN p_start_year integer DEFAULT 2013, IN p_end_year integer DEFAULT 2025, IN p_continue_on_error boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_provider_id smallint;
  v_batch_id bigint;

  y int;
  q int;
  start_date date;
  end_date date;

  v_ok boolean;
  v_rows bigint;
  v_err text;

  t0 timestamptz;
  t1 timestamptz;

  part_rel regclass;
BEGIN
  IF current_setting('transaction_read_only') = 'on' THEN
    RAISE EXCEPTION 'Cannot run backfill in a read-only transaction.';
  END IF;
  
  -- If the client wrapped us in a transaction, internal COMMIT will error.
  -- In that case, refuse up front with a clear message.
  IF txid_current_if_assigned() IS NOT NULL THEN
    -- txid_current_if_assigned() returns NULL if no transaction ID assigned yet,
    -- but many clients start a transaction immediately; this catches that early.
    RAISE EXCEPTION
      'bb.load_drive_day_backfill must be called with autocommit ON (not inside BEGIN/COMMIT).';
  END IF;
  
  SELECT provider_id INTO v_provider_id
  FROM public.provider
  WHERE name='backblaze';

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'Provider backblaze not found in public.provider';
  END IF;

  -- Middle-ground resume: reuse latest unfinished batch if present
  SELECT batch_id INTO v_batch_id
  FROM public.ingest_batch
  WHERE provider_id = v_provider_id
    AND finished_at IS NULL
  ORDER BY started_at DESC
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO public.ingest_batch(provider_id, notes)
    VALUES (v_provider_id,
            format('bb -> public.drive_day backfill %s..%s (quarter commits)', p_start_year, p_end_year))
    RETURNING batch_id INTO v_batch_id;
    
  ELSE
    -- If resuming, optionally mark any stale "running" quarters as interrupted.
    -- (This avoids eternal "running" rows after a crash.)
    UPDATE bb.drive_day_load_log
    SET status = 'interrupted',
        finished_at = clock_timestamp(),
        error = COALESCE(error, 'Resumed batch; previous attempt ended unexpectedly')
    WHERE batch_id = v_batch_id
      AND status = 'running';
      
    -- If we actually interrupted anything, annotate the batch header (polite + auditable)
    IF FOUND THEN
      UPDATE public.ingest_batch
      SET notes = concat_ws(
                   E'\n',
                   NULLIF(notes, ''),
                   format('[%s] Resumed after interruption; prior running quarters marked interrupted.',
                          clock_timestamp())
                 )
      WHERE batch_id = v_batch_id;
    END IF;
    
    COMMIT;
  END IF;

  FOR y IN p_start_year..p_end_year LOOP
    FOR q IN 1..4 LOOP
      start_date := make_date(y, (q*3)-2, 1);
      end_date := (start_date + interval '3 months')::date;

      -- Skip if already done
      IF EXISTS (
        SELECT 1
        FROM bb.drive_day_load_log
        WHERE batch_id = v_batch_id
          AND year = y
          AND quarter = q
          AND status = 'done'
      ) THEN
        CONTINUE;
      END IF;

      -- Start timing for this quarter (real wall clock)
      t0 := clock_timestamp();

      -- Upsert "running" but do NOT overwrite started_at unless we're starting/restarting it
      INSERT INTO bb.drive_day_load_log(batch_id, year, quarter, date_from, date_to, started_at, status, error, finished_at, rows_inserted)
      VALUES (v_batch_id, y, q, start_date, end_date, t0, 'running', NULL, NULL, NULL)
      ON CONFLICT (batch_id, year, quarter) DO UPDATE
        SET date_from = EXCLUDED.date_from,
            date_to   = EXCLUDED.date_to,
            started_at = EXCLUDED.started_at,
            status = 'running',
            error = NULL,
            finished_at = NULL,
            rows_inserted = NULL;

      COMMIT;

      -- Do the load (worker handles exceptions and reports status)
      CALL bb.load_drive_day_quarter(start_date, end_date, v_ok, v_rows, v_err);

      t1 := clock_timestamp();

      IF v_ok THEN
        UPDATE bb.drive_day_load_log
        SET finished_at = t1,
            rows_inserted = v_rows,
            status = 'done',
            error = NULL
        WHERE batch_id = v_batch_id
          AND year = y
          AND quarter = q;

        part_rel := to_regclass(format('public.drive_day_%s_q%s', y, q));
        IF part_rel IS NOT NULL THEN
          EXECUTE format('ANALYZE %s;', part_rel);
        END IF;

        COMMIT;
      ELSE
        UPDATE bb.drive_day_load_log
        SET finished_at = t1,
            rows_inserted = 0,
            status = 'error',
            error = v_err
        WHERE batch_id = v_batch_id
          AND year = y
          AND quarter = q;

        COMMIT;

        IF NOT p_continue_on_error THEN
          RAISE EXCEPTION 'Load failed for % Q% (% to %): %',
            y, q, start_date, end_date, v_err;
        END IF;
      END IF;

    END LOOP;
  END LOOP;

  UPDATE public.ingest_batch
  SET finished_at = clock_timestamp()
  WHERE batch_id = v_batch_id;

  COMMIT;
END$$;


CREATE PROCEDURE bb.load_drive_day_quarter(IN p_from date, IN p_to date, OUT ok boolean, OUT rows_inserted bigint, OUT err text)
    LANGUAGE plpgsql
    AS $$
BEGIN
  ok := true;
  err := NULL;
  rows_inserted := 0;

  BEGIN
    CALL bb.load_drive_day_range(p_from, p_to, rows_inserted);
  EXCEPTION WHEN OTHERS THEN
    ok := false;
    err := SQLERRM;
    rows_inserted := 0;
  END;
END $$;


CREATE PROCEDURE bb.load_drive_day_range(IN p_from date, IN p_to date, OUT rows_inserted bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  SET LOCAL synchronous_commit = off;
  SET LOCAL work_mem = '256MB';

  WITH p AS (
    SELECT provider_id FROM public.provider WHERE name='backblaze'
  )
  INSERT INTO public.drive_day (
    provider_id, drive_id, date, failed,
    location, flags,
    smart_5_raw, smart_5_norm,
    smart_9_raw, smart_9_norm,
    smart_187_raw, smart_187_norm,
    smart_188_raw, smart_188_norm,
    smart_197_raw, smart_197_norm,
    smart_198_raw, smart_198_norm,
    smart_all
  )
  SELECT
    p.provider_id,
    d.drive_id,
    r.date,
    r.failure,

    jsonb_strip_nulls(jsonb_build_object(
      'datacenter', r.datacenter,
      'cluster_id', r.cluster_id,
      'vault_id', r.vault_id,
      'pod_id', r.pod_id,
      'pod_slot_num', r.pod_slot_num
    )),

    jsonb_strip_nulls(jsonb_build_object(
      'is_legacy_format', r.is_legacy_format,
      'source_file', r.source_file
    )),

    r.smart_5_raw,   r.smart_5_normalized,
    r.smart_9_raw,   r.smart_9_normalized,
    r.smart_187_raw, r.smart_187_normalized,
    r.smart_188_raw, r.smart_188_normalized,
    r.smart_197_raw, r.smart_197_normalized,
    r.smart_198_raw, r.smart_198_normalized,

    jsonb_strip_nulls(
      (
        (to_jsonb(r)
          - 'source_file' - 'ingested_at' - 'date' - 'serial_number' - 'model'
          - 'capacity_bytes' - 'failure' - 'datacenter' - 'cluster_id' - 'vault_id'
          - 'pod_id' - 'pod_slot_num' - 'is_legacy_format'
        )
        -- correct misspelling present in BackBlaze's source data
        || jsonb_build_object(
            'smart_211_normalized', r.smart_211_normailized,
            'smart_212_normalized', r.smart_212_normailized
        )
        - 'smart_211_normailized' - 'smart_212_normailized'
      )
    ) AS smart_all

  FROM bb.drive_stats_raw r
  JOIN p ON true
  JOIN LATERAL (
    SELECT candidate.model_id
    FROM (
      SELECT ma.model_id, 1 AS priority
      FROM public.model_alias ma
      WHERE ma.provider_id = p.provider_id
        AND ma.raw_model_name = r.model
        AND ma.is_active

      UNION ALL

      SELECT m2.model_id, 2 AS priority
      FROM public.drive_model m2
      WHERE m2.model_name = r.model

      UNION ALL

      SELECT m3.model_id, 3 AS priority
      FROM public.drive_model m3
      WHERE m3.normalized_name = public.normalize_identifier_text(r.model)
    ) AS candidate
    ORDER BY candidate.priority, candidate.model_id
    LIMIT 1
  ) model_resolve ON true
  JOIN public.drive d
    ON d.provider_id = p.provider_id
   AND d.model_id = model_resolve.model_id
   AND d.serial_number = r.serial_number
  WHERE r.date >= p_from
    AND r.date <  p_to
  ON CONFLICT (provider_id, drive_id, date) DO NOTHING;

  GET DIAGNOSTICS rows_inserted = ROW_COUNT;
END $$;

--
-- TABLES, VIEWS, MATERIALIZED VIEWS, AND SEQUENCES
-- Core data model in dependency order.
--

SET default_table_access_method = heap;


CREATE TABLE bb.drive_day_load_log (
    batch_id bigint NOT NULL,
    year integer NOT NULL,
    quarter integer NOT NULL,
    date_from date NOT NULL,
    date_to date NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    rows_inserted bigint,
    status text DEFAULT 'running'::text NOT NULL,
    error text,
    elapsed interval GENERATED ALWAYS AS (
CASE
    WHEN (finished_at IS NULL) THEN NULL::interval
    ELSE (finished_at - started_at)
END) STORED
);


CREATE TABLE public.ingest_batch (
    batch_id bigint NOT NULL,
    provider_id smallint NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    notes text
);


CREATE TABLE public.provider (
    provider_id smallint NOT NULL,
    name text NOT NULL
);


CREATE VIEW bb.drive_day_backfill AS
 WITH last_batch AS (
         SELECT b.batch_id,
            b.provider_id,
            b.started_at,
            b.finished_at,
            b.notes
           FROM public.ingest_batch b
          WHERE (b.provider_id = ( SELECT provider.provider_id
                   FROM public.provider
                  WHERE (provider.name = 'backblaze'::text)))
          ORDER BY b.started_at DESC
         LIMIT 1
        )
 SELECT lb.batch_id,
    lb.started_at AS batch_started_at,
    lb.finished_at AS batch_finished_at,
    count(*) FILTER (WHERE (l.status = 'done'::text)) AS quarters_done,
    count(*) FILTER (WHERE (l.status = 'running'::text)) AS quarters_running,
    count(*) FILTER (WHERE (l.status = 'interrupted'::text)) AS quarters_interrupted,
    count(*) FILTER (WHERE (l.status = 'error'::text)) AS quarters_error,
    sum(l.rows_inserted) FILTER (WHERE (l.status = 'done'::text)) AS rows_inserted_done
   FROM (last_batch lb
     LEFT JOIN bb.drive_day_load_log l ON ((l.batch_id = lb.batch_id)))
  GROUP BY lb.batch_id, lb.started_at, lb.finished_at;


CREATE VIEW bb.drive_day_backfill_latest AS
 WITH last_batch AS (
         SELECT b.batch_id
           FROM (public.ingest_batch b
             JOIN public.provider p ON ((p.provider_id = b.provider_id)))
          WHERE (p.name = 'backblaze'::text)
          ORDER BY b.started_at DESC
         LIMIT 1
        )
 SELECT l.batch_id,
    l.year,
    l.quarter,
    l.date_from,
    l.date_to,
    l.started_at,
    l.finished_at,
    l.rows_inserted,
    l.status,
    l.error,
    l.elapsed
   FROM (bb.drive_day_load_log l
     JOIN last_batch lb ON ((lb.batch_id = l.batch_id)));


CREATE VIEW bb.drive_day_backfill_qtr AS
 SELECT year,
    quarter,
    status,
    rows_inserted,
    (finished_at - started_at) AS elapsed
   FROM bb.drive_day_load_log
  ORDER BY year, quarter;


CREATE VIEW bb.drive_day_backfill_stuck AS
 SELECT batch_id,
    year,
    quarter,
    date_from,
    date_to,
    started_at,
    finished_at,
    rows_inserted,
    status,
    error,
    elapsed
   FROM bb.drive_day_backfill_latest
  WHERE ((status = 'running'::text) AND ((now() - started_at) > '06:00:00'::interval));


CREATE TABLE bb.drive_stats_raw (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    date date NOT NULL,
    serial_number text NOT NULL,
    model text NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false NOT NULL,
    smart_1_normalized bigint,
    smart_1_raw bigint,
    smart_2_normalized bigint,
    smart_2_raw bigint,
    smart_3_normalized bigint,
    smart_3_raw bigint,
    smart_4_normalized bigint,
    smart_4_raw bigint,
    smart_5_normalized bigint,
    smart_5_raw bigint,
    smart_7_normalized bigint,
    smart_7_raw bigint,
    smart_8_normalized bigint,
    smart_8_raw bigint,
    smart_9_normalized bigint,
    smart_9_raw bigint,
    smart_10_normalized bigint,
    smart_10_raw bigint,
    smart_11_normalized bigint,
    smart_11_raw bigint,
    smart_12_normalized bigint,
    smart_12_raw bigint,
    smart_13_normalized bigint,
    smart_13_raw bigint,
    smart_15_normalized bigint,
    smart_15_raw bigint,
    smart_16_normalized bigint,
    smart_16_raw bigint,
    smart_17_normalized bigint,
    smart_17_raw bigint,
    smart_18_normalized bigint,
    smart_18_raw bigint,
    smart_22_normalized bigint,
    smart_22_raw bigint,
    smart_23_normalized bigint,
    smart_23_raw bigint,
    smart_24_normalized bigint,
    smart_24_raw bigint,
    smart_27_normalized bigint,
    smart_27_raw bigint,
    smart_71_normalized bigint,
    smart_71_raw bigint,
    smart_82_normalized bigint,
    smart_82_raw bigint,
    smart_90_normalized bigint,
    smart_90_raw bigint,
    smart_160_normalized bigint,
    smart_160_raw bigint,
    smart_161_normalized bigint,
    smart_161_raw bigint,
    smart_163_normalized bigint,
    smart_163_raw bigint,
    smart_164_normalized bigint,
    smart_164_raw bigint,
    smart_165_normalized bigint,
    smart_165_raw bigint,
    smart_166_normalized bigint,
    smart_166_raw bigint,
    smart_167_normalized bigint,
    smart_167_raw bigint,
    smart_168_normalized bigint,
    smart_168_raw bigint,
    smart_169_normalized bigint,
    smart_169_raw bigint,
    smart_170_normalized bigint,
    smart_170_raw bigint,
    smart_171_normalized bigint,
    smart_171_raw bigint,
    smart_172_normalized bigint,
    smart_172_raw bigint,
    smart_173_normalized bigint,
    smart_173_raw bigint,
    smart_174_normalized bigint,
    smart_174_raw bigint,
    smart_175_normalized bigint,
    smart_175_raw bigint,
    smart_176_normalized bigint,
    smart_176_raw bigint,
    smart_177_normalized bigint,
    smart_177_raw bigint,
    smart_178_normalized bigint,
    smart_178_raw bigint,
    smart_179_normalized bigint,
    smart_179_raw bigint,
    smart_180_normalized bigint,
    smart_180_raw bigint,
    smart_181_normalized bigint,
    smart_181_raw bigint,
    smart_182_normalized bigint,
    smart_182_raw bigint,
    smart_183_normalized bigint,
    smart_183_raw bigint,
    smart_184_normalized bigint,
    smart_184_raw bigint,
    smart_187_normalized bigint,
    smart_187_raw bigint,
    smart_188_normalized bigint,
    smart_188_raw bigint,
    smart_189_normalized bigint,
    smart_189_raw bigint,
    smart_190_normalized bigint,
    smart_190_raw bigint,
    smart_191_normalized bigint,
    smart_191_raw bigint,
    smart_192_normalized bigint,
    smart_192_raw bigint,
    smart_193_normalized bigint,
    smart_193_raw bigint,
    smart_194_normalized bigint,
    smart_194_raw bigint,
    smart_195_normalized bigint,
    smart_195_raw bigint,
    smart_196_normalized bigint,
    smart_196_raw bigint,
    smart_197_normalized bigint,
    smart_197_raw bigint,
    smart_198_normalized bigint,
    smart_198_raw bigint,
    smart_199_normalized bigint,
    smart_199_raw bigint,
    smart_200_normalized bigint,
    smart_200_raw bigint,
    smart_201_normalized bigint,
    smart_201_raw bigint,
    smart_202_normalized bigint,
    smart_202_raw bigint,
    smart_206_normalized bigint,
    smart_206_raw bigint,
    smart_210_normalized bigint,
    smart_210_raw bigint,
    smart_211_normailized bigint,
    smart_211_raw bigint,
    smart_212_normailized bigint,
    smart_212_raw bigint,
    smart_218_normalized bigint,
    smart_218_raw bigint,
    smart_220_normalized bigint,
    smart_220_raw bigint,
    smart_222_normalized bigint,
    smart_222_raw bigint,
    smart_223_normalized bigint,
    smart_223_raw bigint,
    smart_224_normalized bigint,
    smart_224_raw bigint,
    smart_225_normalized bigint,
    smart_225_raw bigint,
    smart_226_normalized bigint,
    smart_226_raw bigint,
    smart_230_normalized bigint,
    smart_230_raw bigint,
    smart_231_normalized bigint,
    smart_231_raw bigint,
    smart_232_normalized bigint,
    smart_232_raw bigint,
    smart_233_normalized bigint,
    smart_233_raw bigint,
    smart_234_normalized bigint,
    smart_234_raw bigint,
    smart_235_normalized bigint,
    smart_235_raw bigint,
    smart_240_normalized bigint,
    smart_240_raw bigint,
    smart_241_normalized bigint,
    smart_241_raw bigint,
    smart_242_normalized bigint,
    smart_242_raw bigint,
    smart_244_normalized bigint,
    smart_244_raw bigint,
    smart_245_normalized bigint,
    smart_245_raw bigint,
    smart_246_normalized bigint,
    smart_246_raw bigint,
    smart_247_normalized bigint,
    smart_247_raw bigint,
    smart_248_normalized bigint,
    smart_248_raw bigint,
    smart_250_normalized bigint,
    smart_250_raw bigint,
    smart_251_normalized bigint,
    smart_251_raw bigint,
    smart_252_normalized bigint,
    smart_252_raw bigint,
    smart_254_normalized bigint,
    smart_254_raw bigint,
    smart_255_normalized bigint,
    smart_255_raw bigint,
    CONSTRAINT is_legacy_format_not_null_check CHECK (((is_legacy_format IS NOT NULL) OR (source_file IS NOT NULL)))
)
PARTITION BY RANGE (date);


CREATE TABLE bb.ingest_log (
    path text NOT NULL,
    file_size bigint,
    sha256 text,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    rows_loaded bigint,
    rows_skipped bigint
);


CREATE TABLE public.drive (
    drive_id bigint NOT NULL,
    provider_id smallint NOT NULL,
    model_id bigint NOT NULL,
    serial_number text NOT NULL,
    first_seen date,
    last_seen date
);


CREATE TABLE public.drive_day (
    provider_id smallint NOT NULL,
    drive_id bigint NOT NULL,
    date date NOT NULL,
    failed boolean,
    location jsonb,
    flags jsonb,
    smart_5_raw bigint,
    smart_5_norm bigint,
    smart_9_raw bigint,
    smart_9_norm bigint,
    smart_187_raw bigint,
    smart_187_norm bigint,
    smart_188_raw bigint,
    smart_188_norm bigint,
    smart_197_raw bigint,
    smart_197_norm bigint,
    smart_198_raw bigint,
    smart_198_norm bigint,
    smart_all jsonb
)
PARTITION BY RANGE (date);


CREATE MATERIALIZED VIEW public.drive_day_growth AS
 SELECT date_trunc('month'::text, (date)::timestamp with time zone) AS month,
    count(*) AS rows
   FROM public.drive_day
  GROUP BY (date_trunc('month'::text, (date)::timestamp with time zone))
  ORDER BY (date_trunc('month'::text, (date)::timestamp with time zone))
 LIMIT 24
  WITH NO DATA;


CREATE SEQUENCE public.drive_drive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.drive_drive_id_seq OWNED BY public.drive.drive_id;


CREATE TABLE public.drive_model (
    model_id bigint NOT NULL,
    manufacturer_id smallint,
    model_name text NOT NULL,
    normalized_name text GENERATED ALWAYS AS (public.normalize_identifier_text(model_name)) STORED,
    nominal_capacity_bytes bigint,
    media_type text DEFAULT 'unknown'::text NOT NULL,
    interface_type text,
    form_factor text,
    rpm integer
);


COMMENT ON COLUMN public.drive_model.nominal_capacity_bytes IS 'Capacity proxy derived from observed ingest data (currently max reported capacity for the model).';


CREATE MATERIALIZED VIEW public.drive_lifecycle AS
 WITH base AS (
         SELECT d.drive_id,
            m.model_name,
            min(dd.date) AS first_seen,
            max(dd.date) AS last_seen,
            min(dd.date) FILTER (WHERE dd.failed) AS first_failed,
            max(dd.smart_9_raw) AS max_poh
           FROM ((public.drive_day dd
             JOIN public.drive d ON ((d.drive_id = dd.drive_id)))
             JOIN public.drive_model m ON ((m.model_id = d.model_id)))
          GROUP BY d.drive_id, m.model_name
        )
 SELECT drive_id,
    model_name,
    first_seen,
    last_seen,
    first_failed,
    max_poh,
    (first_failed IS NOT NULL) AS failed
   FROM base
  WITH NO DATA;


CREATE SEQUENCE public.drive_model_model_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.drive_model_model_id_seq OWNED BY public.drive_model.model_id;


CREATE TABLE public.model_alias (
    alias_id bigint NOT NULL,
    provider_id smallint NOT NULL,
    raw_model_name text NOT NULL,
    normalized_name text GENERATED ALWAYS AS (public.normalize_identifier_text(raw_model_name)) STORED,
    model_id bigint NOT NULL,
    match_method text DEFAULT 'manual'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


CREATE SEQUENCE public.model_alias_alias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.model_alias_alias_id_seq OWNED BY public.model_alias.alias_id;


CREATE SEQUENCE public.ingest_batch_batch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.ingest_batch_batch_id_seq OWNED BY public.ingest_batch.batch_id;


CREATE TABLE public.manufacturer (
    manufacturer_id smallint NOT NULL,
    name text NOT NULL,
    normalized_name text GENERATED ALWAYS AS (public.normalize_identifier_text(name)) STORED,
    website text,
    headquarters_country text,
    notes text
);


CREATE SEQUENCE public.manufacturer_manufacturer_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.manufacturer_manufacturer_id_seq OWNED BY public.manufacturer.manufacturer_id;


CREATE MATERIALIZED VIEW public.model_hazard_5k AS
 WITH buckets AS (
         SELECT drive_lifecycle.model_name,
            drive_lifecycle.drive_id,
            drive_lifecycle.failed,
            drive_lifecycle.max_poh,
            (floor(((drive_lifecycle.max_poh)::numeric / 5000.0)) * (5000)::numeric) AS poh_bucket
           FROM public.drive_lifecycle
          WHERE (drive_lifecycle.max_poh IS NOT NULL)
        )
 SELECT model_name,
    poh_bucket,
    count(*) AS drives_reaching_bucket,
    count(*) FILTER (WHERE (failed AND ((max_poh)::numeric >= poh_bucket) AND ((max_poh)::numeric < (poh_bucket + (5000)::numeric)))) AS failures_in_bucket
   FROM buckets
  GROUP BY model_name, poh_bucket
  ORDER BY model_name, poh_bucket
  WITH NO DATA;


CREATE MATERIALIZED VIEW public.model_lifetime_stats AS
 SELECT m.model_name,
    count(DISTINCT d.drive_id) AS drives_seen,
    count(*) AS drive_days,
    count(*) FILTER (WHERE dd.failed) AS failures,
    (((count(*) FILTER (WHERE dd.failed))::numeric / (NULLIF(count(*), 0))::numeric) * (365)::numeric) AS failures_per_drive_year,
    percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((dd.smart_9_raw)::double precision)) FILTER (WHERE (dd.failed AND (dd.smart_9_raw IS NOT NULL))) AS median_poh_at_fail,
    avg(((dd.smart_5_raw > 0))::integer) AS realloc_day_rate,
    avg(((dd.smart_197_raw > 0))::integer) AS pending_day_rate,
    avg(((dd.smart_198_raw > 0))::integer) AS offline_unc_day_rate
   FROM ((public.drive_day dd
     JOIN public.drive d ON ((d.drive_id = dd.drive_id)))
     JOIN public.drive_model m ON ((m.model_id = d.model_id)))
  GROUP BY m.model_name
  WITH NO DATA;


CREATE MATERIALIZED VIEW public.model_quarter_stats AS
 SELECT m.model_name,
    (date_part('year'::text, dd.date))::integer AS year,
    ((((date_part('month'::text, dd.date))::integer - 1) / 3) + 1) AS quarter,
    count(*) AS drive_days,
    count(*) FILTER (WHERE dd.failed) AS failures,
    avg(dd.smart_9_raw) FILTER (WHERE (dd.failed AND (dd.smart_9_raw IS NOT NULL))) AS avg_poh_at_fail
   FROM ((public.drive_day dd
     JOIN public.drive d ON ((d.drive_id = dd.drive_id)))
     JOIN public.drive_model m ON ((m.model_id = d.model_id)))
  GROUP BY m.model_name, ((date_part('year'::text, dd.date))::integer), ((((date_part('month'::text, dd.date))::integer - 1) / 3) + 1)
  WITH NO DATA;


CREATE SEQUENCE public.provider_provider_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.provider_provider_id_seq OWNED BY public.provider.provider_id;


ALTER TABLE public.drive ALTER COLUMN drive_id SET DEFAULT nextval('public.drive_drive_id_seq'::regclass);
ALTER TABLE public.drive_model ALTER COLUMN model_id SET DEFAULT nextval('public.drive_model_model_id_seq'::regclass);
ALTER TABLE public.model_alias ALTER COLUMN alias_id SET DEFAULT nextval('public.model_alias_alias_id_seq'::regclass);
ALTER TABLE public.ingest_batch ALTER COLUMN batch_id SET DEFAULT nextval('public.ingest_batch_batch_id_seq'::regclass);
ALTER TABLE public.manufacturer ALTER COLUMN manufacturer_id SET DEFAULT nextval('public.manufacturer_manufacturer_id_seq'::regclass);
ALTER TABLE public.provider ALTER COLUMN provider_id SET DEFAULT nextval('public.provider_provider_id_seq'::regclass);


--
-- SEED DATA
-- Minimal reference rows only.
-- Optional model catalog lives in sql/seed-drive-model.sql.
-- Optional model/manufacturer enrichment lives in sql/seed-drive-model-enrichment.sql.
--

-- Optional: seed drive models from sql/seed-drive-model.sql

INSERT INTO public.manufacturer (manufacturer_id, name) VALUES (1, 'Unknown');
INSERT INTO public.provider (provider_id, name) VALUES (1, 'backblaze');

SELECT pg_catalog.setval('public.drive_drive_id_seq', COALESCE((SELECT max(drive_id) FROM public.drive), 1), EXISTS (SELECT 1 FROM public.drive));
SELECT pg_catalog.setval('public.drive_model_model_id_seq', COALESCE((SELECT max(model_id) FROM public.drive_model), 1), EXISTS (SELECT 1 FROM public.drive_model));
SELECT pg_catalog.setval('public.model_alias_alias_id_seq', COALESCE((SELECT max(alias_id) FROM public.model_alias), 1), EXISTS (SELECT 1 FROM public.model_alias));
SELECT pg_catalog.setval('public.ingest_batch_batch_id_seq', COALESCE((SELECT max(batch_id) FROM public.ingest_batch), 1), EXISTS (SELECT 1 FROM public.ingest_batch));
SELECT pg_catalog.setval('public.manufacturer_manufacturer_id_seq', COALESCE((SELECT max(manufacturer_id) FROM public.manufacturer), 1), EXISTS (SELECT 1 FROM public.manufacturer));
SELECT pg_catalog.setval('public.provider_provider_id_seq', COALESCE((SELECT max(provider_id) FROM public.provider), 1), EXISTS (SELECT 1 FROM public.provider));


ALTER TABLE bb.drive_day_load_log
    ADD CONSTRAINT drive_day_load_log_pkey PRIMARY KEY (batch_id, year, quarter);

ALTER TABLE bb.ingest_log
    ADD CONSTRAINT ingest_log_pkey PRIMARY KEY (path);

ALTER TABLE public.drive_day
    ADD CONSTRAINT drive_day_pkey PRIMARY KEY (provider_id, drive_id, date);

ALTER TABLE public.drive_model
    ADD CONSTRAINT drive_model_model_name_key UNIQUE (model_name);
ALTER TABLE public.drive_model
    ADD CONSTRAINT drive_model_media_type_check CHECK ((media_type = ANY (ARRAY['unknown'::text, 'hdd'::text, 'ssd'::text])));
ALTER TABLE public.drive_model
    ADD CONSTRAINT drive_model_pkey PRIMARY KEY (model_id);

ALTER TABLE public.model_alias
    ADD CONSTRAINT model_alias_pkey PRIMARY KEY (alias_id);
ALTER TABLE public.model_alias
    ADD CONSTRAINT model_alias_provider_id_raw_model_name_key UNIQUE (provider_id, raw_model_name);

ALTER TABLE public.drive
    ADD CONSTRAINT drive_pkey PRIMARY KEY (drive_id);
ALTER TABLE public.drive
    ADD CONSTRAINT drive_provider_id_model_id_serial_number_key UNIQUE (provider_id, model_id, serial_number);

ALTER TABLE public.ingest_batch
    ADD CONSTRAINT ingest_batch_pkey PRIMARY KEY (batch_id);

ALTER TABLE public.manufacturer
    ADD CONSTRAINT manufacturer_name_key UNIQUE (name);
ALTER TABLE public.manufacturer
    ADD CONSTRAINT manufacturer_normalized_name_key UNIQUE (normalized_name);
ALTER TABLE public.manufacturer
    ADD CONSTRAINT manufacturer_pkey PRIMARY KEY (manufacturer_id);

ALTER TABLE public.provider
    ADD CONSTRAINT provider_name_key UNIQUE (name);
ALTER TABLE public.provider
    ADD CONSTRAINT provider_pkey PRIMARY KEY (provider_id);


CREATE INDEX drive_day_load_log_status_idx ON bb.drive_day_load_log USING btree (status) WITH (fillfactor='100', deduplicate_items='true');

CREATE INDEX drive_stats_raw_date_idx ON bb.drive_stats_raw USING brin (date) WITH (pages_per_range='128', autosummarize='true');
CREATE INDEX drive_stats_raw_model_date_idx ON bb.drive_stats_raw USING btree (model, date);
CREATE INDEX drive_stats_raw_serial_number_date_idx ON bb.drive_stats_raw USING btree (serial_number, date);

CREATE INDEX drive_day_date_brin ON public.drive_day USING brin (date) WITH (pages_per_range='128');
CREATE INDEX drive_day_drive_date_idx ON public.drive_day USING btree (drive_id, date);
CREATE INDEX drive_day_failed_date_idx ON public.drive_day USING btree (date) WHERE (failed IS TRUE);

CREATE INDEX drive_lifecycle_failed_idx ON public.drive_lifecycle USING btree (failed);
CREATE INDEX drive_lifecycle_max_poh_idx ON public.drive_lifecycle USING btree (max_poh);
CREATE INDEX drive_lifecycle_model_name_idx ON public.drive_lifecycle USING btree (model_name);

CREATE INDEX drive_model_capacity_idx ON public.drive_model USING btree (nominal_capacity_bytes);
CREATE INDEX drive_model_mfr_capacity_idx ON public.drive_model USING btree (manufacturer_id, nominal_capacity_bytes);
CREATE INDEX drive_model_normalized_name_idx ON public.drive_model USING btree (normalized_name);
CREATE INDEX drive_model_media_type_idx ON public.drive_model USING btree (media_type);

CREATE INDEX model_alias_model_id_idx ON public.model_alias USING btree (model_id);
CREATE INDEX model_alias_normalized_name_idx ON public.model_alias USING btree (provider_id, normalized_name) WHERE (is_active IS TRUE);

CREATE INDEX model_lifetime_stats_drives_seen_idx ON public.model_lifetime_stats USING btree (drives_seen);
CREATE INDEX model_lifetime_stats_failures_per_drive_year_idx ON public.model_lifetime_stats USING btree (failures_per_drive_year);

CREATE INDEX model_quarter_stats_model_name_year_quarter_idx ON public.model_quarter_stats USING btree (model_name, year, quarter);


ALTER TABLE bb.drive_day_load_log
    ADD CONSTRAINT drive_day_load_log_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.ingest_batch(batch_id) ON DELETE CASCADE;

ALTER TABLE public.drive_day
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);
ALTER TABLE public.drive_day
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);

ALTER TABLE public.drive
    ADD CONSTRAINT drive_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.drive_model(model_id);

ALTER TABLE public.drive_model
    ADD CONSTRAINT drive_model_manufacturer_id_fkey FOREIGN KEY (manufacturer_id) REFERENCES public.manufacturer(manufacturer_id);

ALTER TABLE public.model_alias
    ADD CONSTRAINT model_alias_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.drive_model(model_id);
ALTER TABLE public.model_alias
    ADD CONSTRAINT model_alias_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);

ALTER TABLE public.drive
    ADD CONSTRAINT drive_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);

ALTER TABLE public.ingest_batch
    ADD CONSTRAINT ingest_batch_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- OBJECT DOCUMENTATION
-- Keep high-signal metadata close to schema definitions for psql \d+ discovery.
--

COMMENT ON SCHEMA bb IS 'Backblaze provider schema. Raw ingest tables, logs, and provider-specific procedures/views.';

COMMENT ON PROCEDURE bb.load_drive_day_backfill(integer, integer, boolean) IS
  'Top-level quarter-by-quarter backfill from bb.drive_stats_raw into public.drive_day with resumable batch logging.';
COMMENT ON PROCEDURE bb.load_drive_day_quarter(date, date) IS
  'Wrapper that runs one quarter load and reports success/error without aborting caller control flow.';
COMMENT ON PROCEDURE bb.load_drive_day_range(date, date) IS
  'Loads one date range from raw rows into public.drive_day and returns inserted row count, resolving model via alias/canonical normalization.';

COMMENT ON TABLE bb.drive_stats_raw IS
  'Raw Backblaze daily snapshots exactly as ingested (wide SMART schema, partitioned by date).';
COMMENT ON TABLE bb.ingest_log IS
  'File-level ingest bookkeeping for raw CSV files.';
COMMENT ON TABLE bb.drive_day_load_log IS
  'Quarter-level execution log for bb.load_drive_day_backfill batches.';

COMMENT ON COLUMN bb.drive_day_load_log.status IS
  'Execution state for a quarter load: running, done, interrupted, or error.';
COMMENT ON COLUMN bb.drive_day_load_log.elapsed IS
  'Generated runtime from started_at to finished_at.';

COMMENT ON TABLE public.provider IS
  'Data source providers (currently backblaze).';
COMMENT ON TABLE public.ingest_batch IS
  'Batch header for normalization/backfill runs, referenced by detailed provider logs.';
COMMENT ON TABLE public.manufacturer IS
  'Drive manufacturers, and in the future some enriched data about them, possibly.';
COMMENT ON TABLE public.drive_model IS
  'Canonical drive model catalog (provider-agnostic where possible).';
COMMENT ON TABLE public.model_alias IS
  'Provider-scoped mapping from raw imported model strings to canonical drive_model rows.';
COMMENT ON TABLE public.drive IS
  'Physical/logical drive identity scoped by provider + model + serial.';
COMMENT ON TABLE public.drive_day IS
  'Normalized daily fact table for per-drive health/failure observations (partitioned by date).';

COMMENT ON COLUMN public.drive_day.location IS
  'Provider-specific placement metadata (datacenter/cluster/vault/pod/slot when available).';
COMMENT ON COLUMN public.drive_day.flags IS
  'Ingest flags such as legacy format markers and source provenance.';
COMMENT ON COLUMN public.drive_day.smart_all IS
  'Sparse JSONB payload of additional SMART metrics not promoted to dedicated columns.';
COMMENT ON COLUMN public.drive_model.normalized_name IS
  'Generated normalization key for model_name used for loose matching and dedup workflows.';
COMMENT ON COLUMN public.drive_model.media_type IS
  'Coarse media classification: ssd, hdd, or unknown.';
COMMENT ON COLUMN public.drive_model.interface_type IS
  'Optional interface classification (for example: sata, sas, nvme).';
COMMENT ON COLUMN public.drive_model.form_factor IS
  'Optional physical form factor (for example: 2.5in, 3.5in, m.2).';
COMMENT ON COLUMN public.drive_model.rpm IS
  'Optional nominal spindle speed for HDD models.';
COMMENT ON COLUMN public.model_alias.raw_model_name IS
  'As-imported model string from provider data.';
COMMENT ON COLUMN public.model_alias.normalized_name IS
  'Generated normalization key for raw_model_name.';
COMMENT ON COLUMN public.model_alias.match_method IS
  'How the alias was established (manual, seed_exact, rule, etc.).';
COMMENT ON COLUMN public.manufacturer.normalized_name IS
  'Generated normalization key for manufacturer name.';
COMMENT ON COLUMN public.manufacturer.website IS
  'Manufacturer website URL for enrichment.';
COMMENT ON COLUMN public.manufacturer.headquarters_country IS
  'Free-form country/region label for enrichment.';

COMMENT ON VIEW bb.drive_day_backfill IS
  'Summary status for the most recent backfill batch.';
COMMENT ON VIEW bb.drive_day_backfill_latest IS
  'Quarter-by-quarter detail rows for the most recent backfill batch.';
COMMENT ON VIEW bb.drive_day_backfill_qtr IS
  'Show backfill size and processing time for each quarter';
COMMENT ON VIEW bb.drive_day_backfill_stuck IS
  'Running quarter jobs whose runtime has exceeded six hours.';

COMMENT ON MATERIALIZED VIEW public.drive_day_growth IS
  'Monthly breakdown of drive_day data volume';
COMMENT ON MATERIALIZED VIEW public.drive_lifecycle IS
  'Per-drive lifecycle rollup including observation window, first failure date, and max power-on hours.';
COMMENT ON MATERIALIZED VIEW public.model_quarter_stats IS
  'Quarterly model-level drive-day and failure aggregates.';
COMMENT ON MATERIALIZED VIEW public.model_lifetime_stats IS
  'Model-level lifetime aggregates including annualized failure proxy and SMART-derived rates.';
COMMENT ON MATERIALIZED VIEW public.model_hazard_5k IS
  'Model-level failure counts in 5,000 power-on-hour exposure buckets.';
