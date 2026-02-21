--
-- PostgreSQL database dump
--

\restrict shCDSgnznPTlidmnO5rOAM3DVBB8ej3Po0IajnvrpRPqdRJbJLczK7rgRqMUdi7

-- Dumped from database version 18.2 (Debian 18.2-1.pgdg13+1)
-- Dumped by pg_dump version 18.0

-- Started on 2026-02-21 14:37:28 CST

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

DROP DATABASE IF EXISTS diskstats;
--
-- TOC entry 4893 (class 1262 OID 16400)
-- Name: diskstats; Type: DATABASE; Schema: -; Owner: -
--

CREATE DATABASE diskstats WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE_PROVIDER = libc LOCALE = 'en_US.utf8';


\unrestrict shCDSgnznPTlidmnO5rOAM3DVBB8ej3Po0IajnvrpRPqdRJbJLczK7rgRqMUdi7
\connect diskstats
\restrict shCDSgnznPTlidmnO5rOAM3DVBB8ej3Po0IajnvrpRPqdRJbJLczK7rgRqMUdi7

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 4894 (class 0 OID 0)
-- Dependencies: 4893
-- Name: DATABASE diskstats; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON DATABASE diskstats IS 'Disk stats from backblaze and possibly other providers down the road';


--
-- TOC entry 6 (class 2615 OID 16401)
-- Name: bb; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA bb;


--
-- TOC entry 367 (class 1255 OID 33544)
-- Name: load_drive_day_backfill(integer, integer, boolean); Type: PROCEDURE; Schema: bb; Owner: -
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


--
-- TOC entry 366 (class 1255 OID 33545)
-- Name: load_drive_day_quarter(date, date); Type: PROCEDURE; Schema: bb; Owner: -
--

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


--
-- TOC entry 368 (class 1255 OID 35676)
-- Name: load_drive_day_range(date, date); Type: PROCEDURE; Schema: bb; Owner: -
--

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
        || jsonb_build_object(
            'smart_211_normalized', r.smart_211_normailized,
            'smart_212_normalized', r.smart_212_normailized
        )
        - 'smart_211_normailized' - 'smart_212_normailized'
      )
    ) AS smart_all

  FROM bb.drive_stats_raw r
  JOIN p ON true
  JOIN public.drive_model m ON m.model_name = r.model
  JOIN public.drive d
    ON d.provider_id = p.provider_id
   AND d.model_id = m.model_id
   AND d.serial_number = r.serial_number
  WHERE r.date >= p_from
    AND r.date <  p_to
  ON CONFLICT (provider_id, drive_id, date) DO NOTHING;

  GET DIAGNOSTICS rows_inserted = ROW_COUNT;
END $$;


SET default_table_access_method = heap;

--
-- TOC entry 345 (class 1259 OID 36074)
-- Name: drive_day_load_log; Type: TABLE; Schema: bb; Owner: -
--

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


--
-- TOC entry 281 (class 1259 OID 29472)
-- Name: ingest_batch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingest_batch (
    batch_id bigint NOT NULL,
    provider_id smallint NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    notes text
);


--
-- TOC entry 279 (class 1259 OID 29459)
-- Name: provider; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider (
    provider_id smallint NOT NULL,
    name text NOT NULL
);


--
-- TOC entry 346 (class 1259 OID 36097)
-- Name: drive_day_backfill; Type: VIEW; Schema: bb; Owner: -
--

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


--
-- TOC entry 348 (class 1259 OID 36116)
-- Name: drive_day_backfill_latest; Type: VIEW; Schema: bb; Owner: -
--

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


--
-- TOC entry 347 (class 1259 OID 36105)
-- Name: drive_day_backfill_qtr; Type: VIEW; Schema: bb; Owner: -
--

CREATE VIEW bb.drive_day_backfill_qtr AS
 SELECT year,
    quarter,
    status,
    rows_inserted,
    (finished_at - started_at) AS elapsed
   FROM bb.drive_day_load_log
  ORDER BY year, quarter;


--
-- TOC entry 4895 (class 0 OID 0)
-- Dependencies: 347
-- Name: VIEW drive_day_backfill_qtr; Type: COMMENT; Schema: bb; Owner: -
--

COMMENT ON VIEW bb.drive_day_backfill_qtr IS 'Show backfill size and processing time for each quarter';


--
-- TOC entry 349 (class 1259 OID 36121)
-- Name: drive_day_backfill_stuck; Type: VIEW; Schema: bb; Owner: -
--

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


--
-- TOC entry 220 (class 1259 OID 17022)
-- Name: drive_stats_raw; Type: TABLE; Schema: bb; Owner: -
--

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


--
-- TOC entry 266 (class 1259 OID 25961)
-- Name: drive_stats_raw_2013_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2013_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 267 (class 1259 OID 25977)
-- Name: drive_stats_raw_2013_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2013_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 268 (class 1259 OID 25993)
-- Name: drive_stats_raw_2013_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2013_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 269 (class 1259 OID 26009)
-- Name: drive_stats_raw_2013_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2013_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 270 (class 1259 OID 26025)
-- Name: drive_stats_raw_2014_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2014_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 271 (class 1259 OID 26041)
-- Name: drive_stats_raw_2014_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2014_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 272 (class 1259 OID 26057)
-- Name: drive_stats_raw_2014_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2014_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 273 (class 1259 OID 26073)
-- Name: drive_stats_raw_2014_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2014_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 274 (class 1259 OID 26089)
-- Name: drive_stats_raw_2015_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2015_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 275 (class 1259 OID 26105)
-- Name: drive_stats_raw_2015_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2015_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 276 (class 1259 OID 26121)
-- Name: drive_stats_raw_2015_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2015_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 277 (class 1259 OID 26137)
-- Name: drive_stats_raw_2015_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2015_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 221 (class 1259 OID 17033)
-- Name: drive_stats_raw_2016_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2016_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 222 (class 1259 OID 17046)
-- Name: drive_stats_raw_2016_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2016_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 223 (class 1259 OID 17059)
-- Name: drive_stats_raw_2016_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2016_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 224 (class 1259 OID 17072)
-- Name: drive_stats_raw_2016_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2016_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 225 (class 1259 OID 17085)
-- Name: drive_stats_raw_2017_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2017_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 226 (class 1259 OID 17098)
-- Name: drive_stats_raw_2017_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2017_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 227 (class 1259 OID 17111)
-- Name: drive_stats_raw_2017_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2017_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 228 (class 1259 OID 17124)
-- Name: drive_stats_raw_2017_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2017_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 229 (class 1259 OID 17137)
-- Name: drive_stats_raw_2018_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2018_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 230 (class 1259 OID 17150)
-- Name: drive_stats_raw_2018_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2018_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 231 (class 1259 OID 17163)
-- Name: drive_stats_raw_2018_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2018_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 232 (class 1259 OID 17176)
-- Name: drive_stats_raw_2018_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2018_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 233 (class 1259 OID 17189)
-- Name: drive_stats_raw_2019_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2019_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 234 (class 1259 OID 17202)
-- Name: drive_stats_raw_2019_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2019_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 235 (class 1259 OID 17215)
-- Name: drive_stats_raw_2019_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2019_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 236 (class 1259 OID 17228)
-- Name: drive_stats_raw_2019_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2019_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 237 (class 1259 OID 17241)
-- Name: drive_stats_raw_2020_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2020_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 238 (class 1259 OID 17254)
-- Name: drive_stats_raw_2020_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2020_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 239 (class 1259 OID 17267)
-- Name: drive_stats_raw_2020_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2020_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 240 (class 1259 OID 17280)
-- Name: drive_stats_raw_2020_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2020_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 241 (class 1259 OID 17293)
-- Name: drive_stats_raw_2021_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2021_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 242 (class 1259 OID 17306)
-- Name: drive_stats_raw_2021_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2021_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 243 (class 1259 OID 17319)
-- Name: drive_stats_raw_2021_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2021_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 244 (class 1259 OID 17332)
-- Name: drive_stats_raw_2021_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2021_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 245 (class 1259 OID 17345)
-- Name: drive_stats_raw_2022_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2022_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 246 (class 1259 OID 17358)
-- Name: drive_stats_raw_2022_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2022_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 247 (class 1259 OID 17371)
-- Name: drive_stats_raw_2022_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2022_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 248 (class 1259 OID 17384)
-- Name: drive_stats_raw_2022_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2022_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 249 (class 1259 OID 17397)
-- Name: drive_stats_raw_2023_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2023_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 250 (class 1259 OID 17410)
-- Name: drive_stats_raw_2023_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2023_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 251 (class 1259 OID 17423)
-- Name: drive_stats_raw_2023_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2023_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 252 (class 1259 OID 17436)
-- Name: drive_stats_raw_2023_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2023_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 253 (class 1259 OID 17449)
-- Name: drive_stats_raw_2024_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2024_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 254 (class 1259 OID 17462)
-- Name: drive_stats_raw_2024_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2024_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 255 (class 1259 OID 17475)
-- Name: drive_stats_raw_2024_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2024_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 256 (class 1259 OID 17488)
-- Name: drive_stats_raw_2024_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2024_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 257 (class 1259 OID 17501)
-- Name: drive_stats_raw_2025_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2025_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 258 (class 1259 OID 17514)
-- Name: drive_stats_raw_2025_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2025_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 259 (class 1259 OID 17527)
-- Name: drive_stats_raw_2025_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2025_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 260 (class 1259 OID 17540)
-- Name: drive_stats_raw_2025_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2025_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 261 (class 1259 OID 17553)
-- Name: drive_stats_raw_2026_q1; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2026_q1 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 262 (class 1259 OID 17566)
-- Name: drive_stats_raw_2026_q2; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2026_q2 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 263 (class 1259 OID 17579)
-- Name: drive_stats_raw_2026_q3; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2026_q3 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 264 (class 1259 OID 17592)
-- Name: drive_stats_raw_2026_q4; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.drive_stats_raw_2026_q4 (
    source_file text,
    ingested_at timestamp with time zone DEFAULT now() CONSTRAINT drive_stats_raw_ingested_at_not_null NOT NULL,
    date date CONSTRAINT drive_stats_raw_date_not_null NOT NULL,
    serial_number text CONSTRAINT drive_stats_raw_serial_number_not_null NOT NULL,
    model text CONSTRAINT drive_stats_raw_model_not_null NOT NULL,
    capacity_bytes bigint,
    failure boolean,
    datacenter character(4),
    cluster_id smallint,
    vault_id smallint,
    pod_id smallint,
    pod_slot_num smallint,
    is_legacy_format boolean DEFAULT false CONSTRAINT drive_stats_raw_is_legacy_format_not_null NOT NULL,
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
);


--
-- TOC entry 265 (class 1259 OID 24576)
-- Name: ingest_log; Type: TABLE; Schema: bb; Owner: -
--

CREATE TABLE bb.ingest_log (
    path text NOT NULL,
    file_size bigint,
    sha256 text,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    rows_loaded bigint,
    rows_skipped bigint
);


--
-- TOC entry 287 (class 1259 OID 29521)
-- Name: drive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive (
    drive_id bigint NOT NULL,
    provider_id smallint NOT NULL,
    model_id bigint NOT NULL,
    serial_number text NOT NULL,
    first_seen date,
    last_seen date
);


--
-- TOC entry 288 (class 1259 OID 29594)
-- Name: drive_day; Type: TABLE; Schema: public; Owner: -
--

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


--
-- TOC entry 289 (class 1259 OID 29615)
-- Name: drive_day_2013_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2013_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 290 (class 1259 OID 29634)
-- Name: drive_day_2013_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2013_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 291 (class 1259 OID 29653)
-- Name: drive_day_2013_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2013_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 292 (class 1259 OID 29672)
-- Name: drive_day_2013_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2013_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 293 (class 1259 OID 29691)
-- Name: drive_day_2014_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2014_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 294 (class 1259 OID 29710)
-- Name: drive_day_2014_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2014_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 295 (class 1259 OID 29729)
-- Name: drive_day_2014_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2014_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 296 (class 1259 OID 29748)
-- Name: drive_day_2014_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2014_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 297 (class 1259 OID 29767)
-- Name: drive_day_2015_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2015_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 298 (class 1259 OID 29786)
-- Name: drive_day_2015_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2015_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 299 (class 1259 OID 29805)
-- Name: drive_day_2015_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2015_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 300 (class 1259 OID 29824)
-- Name: drive_day_2015_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2015_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 301 (class 1259 OID 29843)
-- Name: drive_day_2016_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2016_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 302 (class 1259 OID 29862)
-- Name: drive_day_2016_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2016_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 303 (class 1259 OID 29881)
-- Name: drive_day_2016_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2016_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 304 (class 1259 OID 29900)
-- Name: drive_day_2016_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2016_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 305 (class 1259 OID 29919)
-- Name: drive_day_2017_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2017_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 306 (class 1259 OID 29938)
-- Name: drive_day_2017_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2017_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 307 (class 1259 OID 29957)
-- Name: drive_day_2017_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2017_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 308 (class 1259 OID 29976)
-- Name: drive_day_2017_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2017_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 309 (class 1259 OID 29995)
-- Name: drive_day_2018_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2018_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 310 (class 1259 OID 30014)
-- Name: drive_day_2018_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2018_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 311 (class 1259 OID 30033)
-- Name: drive_day_2018_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2018_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 312 (class 1259 OID 30052)
-- Name: drive_day_2018_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2018_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 313 (class 1259 OID 30071)
-- Name: drive_day_2019_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2019_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 314 (class 1259 OID 30090)
-- Name: drive_day_2019_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2019_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 315 (class 1259 OID 30109)
-- Name: drive_day_2019_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2019_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 316 (class 1259 OID 30128)
-- Name: drive_day_2019_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2019_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 317 (class 1259 OID 30147)
-- Name: drive_day_2020_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2020_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 318 (class 1259 OID 30166)
-- Name: drive_day_2020_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2020_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 319 (class 1259 OID 30185)
-- Name: drive_day_2020_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2020_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 320 (class 1259 OID 30204)
-- Name: drive_day_2020_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2020_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 321 (class 1259 OID 30223)
-- Name: drive_day_2021_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2021_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 322 (class 1259 OID 30242)
-- Name: drive_day_2021_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2021_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 323 (class 1259 OID 30261)
-- Name: drive_day_2021_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2021_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 324 (class 1259 OID 30280)
-- Name: drive_day_2021_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2021_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 325 (class 1259 OID 30299)
-- Name: drive_day_2022_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2022_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 326 (class 1259 OID 30318)
-- Name: drive_day_2022_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2022_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 327 (class 1259 OID 30337)
-- Name: drive_day_2022_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2022_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 328 (class 1259 OID 30356)
-- Name: drive_day_2022_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2022_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 329 (class 1259 OID 30375)
-- Name: drive_day_2023_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2023_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 330 (class 1259 OID 30394)
-- Name: drive_day_2023_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2023_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 331 (class 1259 OID 30413)
-- Name: drive_day_2023_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2023_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 332 (class 1259 OID 30432)
-- Name: drive_day_2023_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2023_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 333 (class 1259 OID 30451)
-- Name: drive_day_2024_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2024_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 334 (class 1259 OID 30470)
-- Name: drive_day_2024_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2024_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 335 (class 1259 OID 30489)
-- Name: drive_day_2024_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2024_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 336 (class 1259 OID 30508)
-- Name: drive_day_2024_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2024_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 337 (class 1259 OID 30527)
-- Name: drive_day_2025_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2025_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 338 (class 1259 OID 30546)
-- Name: drive_day_2025_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2025_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 339 (class 1259 OID 30565)
-- Name: drive_day_2025_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2025_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 340 (class 1259 OID 30584)
-- Name: drive_day_2025_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2025_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 341 (class 1259 OID 30603)
-- Name: drive_day_2026_q1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2026_q1 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 342 (class 1259 OID 30622)
-- Name: drive_day_2026_q2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2026_q2 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 343 (class 1259 OID 30641)
-- Name: drive_day_2026_q3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2026_q3 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 344 (class 1259 OID 30660)
-- Name: drive_day_2026_q4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_day_2026_q4 (
    provider_id smallint CONSTRAINT drive_day_provider_id_not_null NOT NULL,
    drive_id bigint CONSTRAINT drive_day_drive_id_not_null NOT NULL,
    date date CONSTRAINT drive_day_date_not_null NOT NULL,
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
);


--
-- TOC entry 354 (class 1259 OID 37377)
-- Name: drive_day_growth; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.drive_day_growth AS
 SELECT date_trunc('month'::text, (date)::timestamp with time zone) AS month,
    count(*) AS rows
   FROM public.drive_day
  GROUP BY (date_trunc('month'::text, (date)::timestamp with time zone))
  ORDER BY (date_trunc('month'::text, (date)::timestamp with time zone))
 LIMIT 24
  WITH NO DATA;


--
-- TOC entry 4896 (class 0 OID 0)
-- Dependencies: 354
-- Name: MATERIALIZED VIEW drive_day_growth; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON MATERIALIZED VIEW public.drive_day_growth IS 'Monthly breakdown of drive_day data volume';


--
-- TOC entry 286 (class 1259 OID 29520)
-- Name: drive_drive_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.drive_drive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4897 (class 0 OID 0)
-- Dependencies: 286
-- Name: drive_drive_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.drive_drive_id_seq OWNED BY public.drive.drive_id;


--
-- TOC entry 285 (class 1259 OID 29503)
-- Name: drive_model; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drive_model (
    model_id bigint NOT NULL,
    manufacturer_id smallint,
    model_name text NOT NULL,
    nominal_capacity_bytes bigint
);


--
-- TOC entry 4898 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN drive_model.nominal_capacity_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.drive_model.nominal_capacity_bytes IS 'This is formed from ingest by simply taking the largest drive size reported from the ingested datasets. TODO: make a computed row?';


--
-- TOC entry 352 (class 1259 OID 36324)
-- Name: drive_lifecycle; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

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


--
-- TOC entry 284 (class 1259 OID 29502)
-- Name: drive_model_model_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.drive_model_model_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4899 (class 0 OID 0)
-- Dependencies: 284
-- Name: drive_model_model_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.drive_model_model_id_seq OWNED BY public.drive_model.model_id;


--
-- TOC entry 280 (class 1259 OID 29471)
-- Name: ingest_batch_batch_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ingest_batch_batch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4900 (class 0 OID 0)
-- Dependencies: 280
-- Name: ingest_batch_batch_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ingest_batch_batch_id_seq OWNED BY public.ingest_batch.batch_id;


--
-- TOC entry 283 (class 1259 OID 29490)
-- Name: manufacturer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manufacturer (
    manufacturer_id smallint NOT NULL,
    name text NOT NULL
);


--
-- TOC entry 4901 (class 0 OID 0)
-- Dependencies: 283
-- Name: TABLE manufacturer; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.manufacturer IS 'Drive manufacturers, and in the future some enriched data about them, possibly.';


--
-- TOC entry 282 (class 1259 OID 29489)
-- Name: manufacturer_manufacturer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.manufacturer_manufacturer_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4902 (class 0 OID 0)
-- Dependencies: 282
-- Name: manufacturer_manufacturer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.manufacturer_manufacturer_id_seq OWNED BY public.manufacturer.manufacturer_id;


--
-- TOC entry 353 (class 1259 OID 36340)
-- Name: model_hazard_5k; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

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


--
-- TOC entry 351 (class 1259 OID 36309)
-- Name: model_lifetime_stats; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

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


--
-- TOC entry 350 (class 1259 OID 36293)
-- Name: model_quarter_stats; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

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


--
-- TOC entry 278 (class 1259 OID 29458)
-- Name: provider_provider_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_provider_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- TOC entry 4903 (class 0 OID 0)
-- Dependencies: 278
-- Name: provider_provider_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_provider_id_seq OWNED BY public.provider.provider_id;


--
-- TOC entry 3933 (class 2604 OID 29524)
-- Name: drive drive_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive ALTER COLUMN drive_id SET DEFAULT nextval('public.drive_drive_id_seq'::regclass);


--
-- TOC entry 3932 (class 2604 OID 29506)
-- Name: drive_model model_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_model ALTER COLUMN model_id SET DEFAULT nextval('public.drive_model_model_id_seq'::regclass);


--
-- TOC entry 3929 (class 2604 OID 29475)
-- Name: ingest_batch batch_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingest_batch ALTER COLUMN batch_id SET DEFAULT nextval('public.ingest_batch_batch_id_seq'::regclass);


--
-- TOC entry 3931 (class 2604 OID 29493)
-- Name: manufacturer manufacturer_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manufacturer ALTER COLUMN manufacturer_id SET DEFAULT nextval('public.manufacturer_manufacturer_id_seq'::regclass);


--
-- TOC entry 3928 (class 2604 OID 29462)
-- Name: provider provider_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider ALTER COLUMN provider_id SET DEFAULT nextval('public.provider_provider_id_seq'::regclass);


--
-- TOC entry 4882 (class 0 OID 36074)
-- Dependencies: 345
-- Data for Name: drive_day_load_log; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4804 (class 0 OID 25961)
-- Dependencies: 266
-- Data for Name: drive_stats_raw_2013_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4805 (class 0 OID 25977)
-- Dependencies: 267
-- Data for Name: drive_stats_raw_2013_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4806 (class 0 OID 25993)
-- Dependencies: 268
-- Data for Name: drive_stats_raw_2013_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4807 (class 0 OID 26009)
-- Dependencies: 269
-- Data for Name: drive_stats_raw_2013_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4808 (class 0 OID 26025)
-- Dependencies: 270
-- Data for Name: drive_stats_raw_2014_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4809 (class 0 OID 26041)
-- Dependencies: 271
-- Data for Name: drive_stats_raw_2014_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4810 (class 0 OID 26057)
-- Dependencies: 272
-- Data for Name: drive_stats_raw_2014_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4811 (class 0 OID 26073)
-- Dependencies: 273
-- Data for Name: drive_stats_raw_2014_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4812 (class 0 OID 26089)
-- Dependencies: 274
-- Data for Name: drive_stats_raw_2015_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4813 (class 0 OID 26105)
-- Dependencies: 275
-- Data for Name: drive_stats_raw_2015_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4814 (class 0 OID 26121)
-- Dependencies: 276
-- Data for Name: drive_stats_raw_2015_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4815 (class 0 OID 26137)
-- Dependencies: 277
-- Data for Name: drive_stats_raw_2015_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4759 (class 0 OID 17033)
-- Dependencies: 221
-- Data for Name: drive_stats_raw_2016_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4760 (class 0 OID 17046)
-- Dependencies: 222
-- Data for Name: drive_stats_raw_2016_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4761 (class 0 OID 17059)
-- Dependencies: 223
-- Data for Name: drive_stats_raw_2016_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4762 (class 0 OID 17072)
-- Dependencies: 224
-- Data for Name: drive_stats_raw_2016_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4763 (class 0 OID 17085)
-- Dependencies: 225
-- Data for Name: drive_stats_raw_2017_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4764 (class 0 OID 17098)
-- Dependencies: 226
-- Data for Name: drive_stats_raw_2017_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4765 (class 0 OID 17111)
-- Dependencies: 227
-- Data for Name: drive_stats_raw_2017_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4766 (class 0 OID 17124)
-- Dependencies: 228
-- Data for Name: drive_stats_raw_2017_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4767 (class 0 OID 17137)
-- Dependencies: 229
-- Data for Name: drive_stats_raw_2018_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4768 (class 0 OID 17150)
-- Dependencies: 230
-- Data for Name: drive_stats_raw_2018_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4769 (class 0 OID 17163)
-- Dependencies: 231
-- Data for Name: drive_stats_raw_2018_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4770 (class 0 OID 17176)
-- Dependencies: 232
-- Data for Name: drive_stats_raw_2018_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4771 (class 0 OID 17189)
-- Dependencies: 233
-- Data for Name: drive_stats_raw_2019_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4772 (class 0 OID 17202)
-- Dependencies: 234
-- Data for Name: drive_stats_raw_2019_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4773 (class 0 OID 17215)
-- Dependencies: 235
-- Data for Name: drive_stats_raw_2019_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4774 (class 0 OID 17228)
-- Dependencies: 236
-- Data for Name: drive_stats_raw_2019_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4775 (class 0 OID 17241)
-- Dependencies: 237
-- Data for Name: drive_stats_raw_2020_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4776 (class 0 OID 17254)
-- Dependencies: 238
-- Data for Name: drive_stats_raw_2020_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4777 (class 0 OID 17267)
-- Dependencies: 239
-- Data for Name: drive_stats_raw_2020_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4778 (class 0 OID 17280)
-- Dependencies: 240
-- Data for Name: drive_stats_raw_2020_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4779 (class 0 OID 17293)
-- Dependencies: 241
-- Data for Name: drive_stats_raw_2021_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4780 (class 0 OID 17306)
-- Dependencies: 242
-- Data for Name: drive_stats_raw_2021_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4781 (class 0 OID 17319)
-- Dependencies: 243
-- Data for Name: drive_stats_raw_2021_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4782 (class 0 OID 17332)
-- Dependencies: 244
-- Data for Name: drive_stats_raw_2021_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4783 (class 0 OID 17345)
-- Dependencies: 245
-- Data for Name: drive_stats_raw_2022_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4784 (class 0 OID 17358)
-- Dependencies: 246
-- Data for Name: drive_stats_raw_2022_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4785 (class 0 OID 17371)
-- Dependencies: 247
-- Data for Name: drive_stats_raw_2022_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4786 (class 0 OID 17384)
-- Dependencies: 248
-- Data for Name: drive_stats_raw_2022_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4787 (class 0 OID 17397)
-- Dependencies: 249
-- Data for Name: drive_stats_raw_2023_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4788 (class 0 OID 17410)
-- Dependencies: 250
-- Data for Name: drive_stats_raw_2023_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4789 (class 0 OID 17423)
-- Dependencies: 251
-- Data for Name: drive_stats_raw_2023_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4790 (class 0 OID 17436)
-- Dependencies: 252
-- Data for Name: drive_stats_raw_2023_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4791 (class 0 OID 17449)
-- Dependencies: 253
-- Data for Name: drive_stats_raw_2024_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4792 (class 0 OID 17462)
-- Dependencies: 254
-- Data for Name: drive_stats_raw_2024_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4793 (class 0 OID 17475)
-- Dependencies: 255
-- Data for Name: drive_stats_raw_2024_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4794 (class 0 OID 17488)
-- Dependencies: 256
-- Data for Name: drive_stats_raw_2024_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4795 (class 0 OID 17501)
-- Dependencies: 257
-- Data for Name: drive_stats_raw_2025_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4796 (class 0 OID 17514)
-- Dependencies: 258
-- Data for Name: drive_stats_raw_2025_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4797 (class 0 OID 17527)
-- Dependencies: 259
-- Data for Name: drive_stats_raw_2025_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4798 (class 0 OID 17540)
-- Dependencies: 260
-- Data for Name: drive_stats_raw_2025_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4799 (class 0 OID 17553)
-- Dependencies: 261
-- Data for Name: drive_stats_raw_2026_q1; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4800 (class 0 OID 17566)
-- Dependencies: 262
-- Data for Name: drive_stats_raw_2026_q2; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4801 (class 0 OID 17579)
-- Dependencies: 263
-- Data for Name: drive_stats_raw_2026_q3; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4802 (class 0 OID 17592)
-- Dependencies: 264
-- Data for Name: drive_stats_raw_2026_q4; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4803 (class 0 OID 24576)
-- Dependencies: 265
-- Data for Name: ingest_log; Type: TABLE DATA; Schema: bb; Owner: -
--



--
-- TOC entry 4825 (class 0 OID 29521)
-- Dependencies: 287
-- Data for Name: drive; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4826 (class 0 OID 29615)
-- Dependencies: 289
-- Data for Name: drive_day_2013_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4827 (class 0 OID 29634)
-- Dependencies: 290
-- Data for Name: drive_day_2013_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4828 (class 0 OID 29653)
-- Dependencies: 291
-- Data for Name: drive_day_2013_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4829 (class 0 OID 29672)
-- Dependencies: 292
-- Data for Name: drive_day_2013_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4830 (class 0 OID 29691)
-- Dependencies: 293
-- Data for Name: drive_day_2014_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4831 (class 0 OID 29710)
-- Dependencies: 294
-- Data for Name: drive_day_2014_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4832 (class 0 OID 29729)
-- Dependencies: 295
-- Data for Name: drive_day_2014_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4833 (class 0 OID 29748)
-- Dependencies: 296
-- Data for Name: drive_day_2014_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4834 (class 0 OID 29767)
-- Dependencies: 297
-- Data for Name: drive_day_2015_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4835 (class 0 OID 29786)
-- Dependencies: 298
-- Data for Name: drive_day_2015_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4836 (class 0 OID 29805)
-- Dependencies: 299
-- Data for Name: drive_day_2015_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4837 (class 0 OID 29824)
-- Dependencies: 300
-- Data for Name: drive_day_2015_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4838 (class 0 OID 29843)
-- Dependencies: 301
-- Data for Name: drive_day_2016_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4839 (class 0 OID 29862)
-- Dependencies: 302
-- Data for Name: drive_day_2016_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4840 (class 0 OID 29881)
-- Dependencies: 303
-- Data for Name: drive_day_2016_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4841 (class 0 OID 29900)
-- Dependencies: 304
-- Data for Name: drive_day_2016_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4842 (class 0 OID 29919)
-- Dependencies: 305
-- Data for Name: drive_day_2017_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4843 (class 0 OID 29938)
-- Dependencies: 306
-- Data for Name: drive_day_2017_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4844 (class 0 OID 29957)
-- Dependencies: 307
-- Data for Name: drive_day_2017_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4845 (class 0 OID 29976)
-- Dependencies: 308
-- Data for Name: drive_day_2017_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4846 (class 0 OID 29995)
-- Dependencies: 309
-- Data for Name: drive_day_2018_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4847 (class 0 OID 30014)
-- Dependencies: 310
-- Data for Name: drive_day_2018_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4848 (class 0 OID 30033)
-- Dependencies: 311
-- Data for Name: drive_day_2018_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4849 (class 0 OID 30052)
-- Dependencies: 312
-- Data for Name: drive_day_2018_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4850 (class 0 OID 30071)
-- Dependencies: 313
-- Data for Name: drive_day_2019_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4851 (class 0 OID 30090)
-- Dependencies: 314
-- Data for Name: drive_day_2019_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4852 (class 0 OID 30109)
-- Dependencies: 315
-- Data for Name: drive_day_2019_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4853 (class 0 OID 30128)
-- Dependencies: 316
-- Data for Name: drive_day_2019_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4854 (class 0 OID 30147)
-- Dependencies: 317
-- Data for Name: drive_day_2020_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4855 (class 0 OID 30166)
-- Dependencies: 318
-- Data for Name: drive_day_2020_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4856 (class 0 OID 30185)
-- Dependencies: 319
-- Data for Name: drive_day_2020_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4857 (class 0 OID 30204)
-- Dependencies: 320
-- Data for Name: drive_day_2020_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4858 (class 0 OID 30223)
-- Dependencies: 321
-- Data for Name: drive_day_2021_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4859 (class 0 OID 30242)
-- Dependencies: 322
-- Data for Name: drive_day_2021_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4860 (class 0 OID 30261)
-- Dependencies: 323
-- Data for Name: drive_day_2021_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4861 (class 0 OID 30280)
-- Dependencies: 324
-- Data for Name: drive_day_2021_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4862 (class 0 OID 30299)
-- Dependencies: 325
-- Data for Name: drive_day_2022_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4863 (class 0 OID 30318)
-- Dependencies: 326
-- Data for Name: drive_day_2022_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4864 (class 0 OID 30337)
-- Dependencies: 327
-- Data for Name: drive_day_2022_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4865 (class 0 OID 30356)
-- Dependencies: 328
-- Data for Name: drive_day_2022_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4866 (class 0 OID 30375)
-- Dependencies: 329
-- Data for Name: drive_day_2023_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4867 (class 0 OID 30394)
-- Dependencies: 330
-- Data for Name: drive_day_2023_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4868 (class 0 OID 30413)
-- Dependencies: 331
-- Data for Name: drive_day_2023_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4869 (class 0 OID 30432)
-- Dependencies: 332
-- Data for Name: drive_day_2023_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4870 (class 0 OID 30451)
-- Dependencies: 333
-- Data for Name: drive_day_2024_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4871 (class 0 OID 30470)
-- Dependencies: 334
-- Data for Name: drive_day_2024_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4872 (class 0 OID 30489)
-- Dependencies: 335
-- Data for Name: drive_day_2024_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4873 (class 0 OID 30508)
-- Dependencies: 336
-- Data for Name: drive_day_2024_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4874 (class 0 OID 30527)
-- Dependencies: 337
-- Data for Name: drive_day_2025_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4875 (class 0 OID 30546)
-- Dependencies: 338
-- Data for Name: drive_day_2025_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4876 (class 0 OID 30565)
-- Dependencies: 339
-- Data for Name: drive_day_2025_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4877 (class 0 OID 30584)
-- Dependencies: 340
-- Data for Name: drive_day_2025_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4878 (class 0 OID 30603)
-- Dependencies: 341
-- Data for Name: drive_day_2026_q1; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4879 (class 0 OID 30622)
-- Dependencies: 342
-- Data for Name: drive_day_2026_q2; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4880 (class 0 OID 30641)
-- Dependencies: 343
-- Data for Name: drive_day_2026_q3; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4881 (class 0 OID 30660)
-- Dependencies: 344
-- Data for Name: drive_day_2026_q4; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4823 (class 0 OID 29503)
-- Dependencies: 285
-- Data for Name: drive_model; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.drive_model VALUES (1, 1, 'HGST HUH728080ALE604', 8001563222016);
INSERT INTO public.drive_model VALUES (2, 1, 'TOSHIBA MQ01ABF050', 500108000000);
INSERT INTO public.drive_model VALUES (3, 1, 'SSDSCKKB240GZR', 240057409536);
INSERT INTO public.drive_model VALUES (4, 1, 'WDC WD3200AAKS', 320073000000);
INSERT INTO public.drive_model VALUES (5, 1, 'ST18000NM000J', 18000207937536);
INSERT INTO public.drive_model VALUES (6, 1, 'WDC WD1600AAJB', 160041885696);
INSERT INTO public.drive_model VALUES (7, 1, 'WDC WD2500BPVT', 250059350016);
INSERT INTO public.drive_model VALUES (8, 1, 'HGST HMS5C4040BLE641', 4000787030016);
INSERT INTO public.drive_model VALUES (9, 1, 'ST8000NM0055', 8001563222016);
INSERT INTO public.drive_model VALUES (10, 1, 'WDC WD3200LPVX', 320073000000);
INSERT INTO public.drive_model VALUES (11, 1, 'HGST HUH728080ALE600', 8001563222016);
INSERT INTO public.drive_model VALUES (12, 1, 'ST14000NM0138', 14000519643136);
INSERT INTO public.drive_model VALUES (13, 1, 'WDC WD15EARS', 1500301910016);
INSERT INTO public.drive_model VALUES (14, 1, 'ST2000DL001', 2000398934016);
INSERT INTO public.drive_model VALUES (15, 1, 'ST12000NM001G', 12000138625024);
INSERT INTO public.drive_model VALUES (16, 1, 'WDC WD3200AAJS', 320073000000);
INSERT INTO public.drive_model VALUES (17, 1, 'ST8000DM002', 8001563222016);
INSERT INTO public.drive_model VALUES (18, 1, 'Hitachi HDT725025VLA380', 250000000000);
INSERT INTO public.drive_model VALUES (19, 1, 'ST4000DX002', 4000790000000);
INSERT INTO public.drive_model VALUES (20, 1, 'WDC WUH721816ALE6L0', 16000900661248);
INSERT INTO public.drive_model VALUES (21, 1, 'WDC WD800BB', 80026361856);
INSERT INTO public.drive_model VALUES (22, 1, 'TOSHIBA MG07ACA14TEY', 14000519643136);
INSERT INTO public.drive_model VALUES (23, 1, 'WDC WD5000AAJS', 500107862016);
INSERT INTO public.drive_model VALUES (24, 1, 'ST4000DM005', 4000790000000);
INSERT INTO public.drive_model VALUES (25, 1, 'WDC  WUH721816ALE6L0', 16000900661248);
INSERT INTO public.drive_model VALUES (26, 1, 'ST16000NM001G', 16000900661248);
INSERT INTO public.drive_model VALUES (27, 1, 'Samsung SSD 870 EVO 2TB', 2000398934016);
INSERT INTO public.drive_model VALUES (28, 1, 'ST2000VN000', 2000398934016);
INSERT INTO public.drive_model VALUES (29, 1, 'ST3500320AS', 500107862016);
INSERT INTO public.drive_model VALUES (30, 1, 'Hitachi HDS724040ALE640', 4000790000000);
INSERT INTO public.drive_model VALUES (31, 1, 'WDC WD1001FALS', 1000204886016);
INSERT INTO public.drive_model VALUES (32, 1, 'MTFDDAV240TCB', 240057409536);
INSERT INTO public.drive_model VALUES (33, 1, 'TOSHIBA MQ01ABF050M', 500108000000);
INSERT INTO public.drive_model VALUES (34, 1, 'ST33000651AS', 3000592982016);
INSERT INTO public.drive_model VALUES (35, 1, 'TOSHIBA MD04ABA400V', 4000790000000);
INSERT INTO public.drive_model VALUES (36, 1, 'HGST HUS726040ALE610', 4000790000000);
INSERT INTO public.drive_model VALUES (37, 1, 'Seagate SSD', 250059350016);
INSERT INTO public.drive_model VALUES (38, 1, 'Seagate BarraCuda 120 SSD ZA500CM10003', 500107862016);
INSERT INTO public.drive_model VALUES (39, 1, 'HGST HUH721010ALE600', 10000831348736);
INSERT INTO public.drive_model VALUES (40, 1, 'ST8000NM000A', 8001563222016);
INSERT INTO public.drive_model VALUES (41, 1, 'MTFDDAV240TDU', 240057409536);
INSERT INTO public.drive_model VALUES (42, 1, 'ST6000DM004', 6001180000000);
INSERT INTO public.drive_model VALUES (43, 1, 'WDC WD1000FYPS', 1000204886016);
INSERT INTO public.drive_model VALUES (44, 1, 'WDC WD15EADS', 1500301910016);
INSERT INTO public.drive_model VALUES (45, 1, 'ST4000DM004', 4000787030016);
INSERT INTO public.drive_model VALUES (46, 1, 'ST9250315AS', 250059350016);
INSERT INTO public.drive_model VALUES (47, 1, 'HGST HDS5C4040ALE630', 4000790000000);
INSERT INTO public.drive_model VALUES (48, 1, 'Hitachi HDS723030BLE640', 3000592982016);
INSERT INTO public.drive_model VALUES (49, 1, 'ST3000DM001', 3000592982016);
INSERT INTO public.drive_model VALUES (50, 1, 'ST500LM012 HN', 500108000000);
INSERT INTO public.drive_model VALUES (51, 1, 'ST10000NM001G', 10000831348736);
INSERT INTO public.drive_model VALUES (52, 1, 'TOSHIBA HDWE160', 6001180000000);
INSERT INTO public.drive_model VALUES (53, 1, 'WDC WD2500AAJS', 250059350016);
INSERT INTO public.drive_model VALUES (54, 1, 'WDC WD30EFRX', 3000592982016);
INSERT INTO public.drive_model VALUES (55, 1, 'MTFDDAV480TDS', 480103981056);
INSERT INTO public.drive_model VALUES (56, 1, 'WDC  WUH721414ALE6L4', 14000519643136);
INSERT INTO public.drive_model VALUES (57, 1, 'Seagate BarraCuda 120 SSD ZA250CM10003', 250059350016);
INSERT INTO public.drive_model VALUES (58, 1, 'WDC  WDS250G2B0A', 250059350016);
INSERT INTO public.drive_model VALUES (59, 1, 'WDC WUH721414ALE6L4', 14000519643136);
INSERT INTO public.drive_model VALUES (60, 1, 'HGST HMS5C4040BLE640', 4000790000000);
INSERT INTO public.drive_model VALUES (61, 1, 'WDC WD5000BPKT', 500108000000);
INSERT INTO public.drive_model VALUES (62, 1, 'WDC WD5000LPVX', 500108000000);
INSERT INTO public.drive_model VALUES (63, 1, 'Hitachi HDS723030ALA640', 3000592982016);
INSERT INTO public.drive_model VALUES (64, 1, 'WDC WD2500BEVT', 250059350016);
INSERT INTO public.drive_model VALUES (65, 1, 'ST4000DM000', 600332565813390450);
INSERT INTO public.drive_model VALUES (66, 1, 'WDC WD5002ABYS', 500107862016);
INSERT INTO public.drive_model VALUES (67, 1, 'ST320005XXXX', 2000398934016);
INSERT INTO public.drive_model VALUES (68, 1, 'Hitachi HDS5C3030ALA630', 3000592982016);
INSERT INTO public.drive_model VALUES (69, 1, 'Samsung SSD 860 PRO 2TB', 2048408248320);
INSERT INTO public.drive_model VALUES (70, 1, 'ST12000NM003G', 12000138625024);
INSERT INTO public.drive_model VALUES (71, 1, 'HGST HUH721212ALN604', 12000138625024);
INSERT INTO public.drive_model VALUES (72, 1, 'WDC WD3200BEKX', 320073000000);
INSERT INTO public.drive_model VALUES (73, 1, 'TOSHIBA MD04ABA500V', 5000981078016);
INSERT INTO public.drive_model VALUES (74, 1, 'WDC WDS250G2B0A', 250059350016);
INSERT INTO public.drive_model VALUES (75, 1, 'HGST HUH721212ALE600', 12000138625024);
INSERT INTO public.drive_model VALUES (76, 1, 'Seagate BarraCuda SSD ZA250CM10002', 250059350016);
INSERT INTO public.drive_model VALUES (77, 1, 'ST1000LM024 HN', 1000204886016);
INSERT INTO public.drive_model VALUES (78, 1, 'WDC WD60EFRX', 6001180000000);
INSERT INTO public.drive_model VALUES (79, 1, 'DELLBOSS VD', 480036847616);
INSERT INTO public.drive_model VALUES (80, 1, 'ST31500341AS', 1500301910016);
INSERT INTO public.drive_model VALUES (81, 1, 'WDC WD1600AAJS', 160042000000);
INSERT INTO public.drive_model VALUES (82, 1, 'WDC WD30EZRS', 3000592982016);
INSERT INTO public.drive_model VALUES (83, 1, 'ST24000NM002H', 24000277250048);
INSERT INTO public.drive_model VALUES (84, 1, 'SAMSUNG HD103UJ', 1000204886016);
INSERT INTO public.drive_model VALUES (85, 1, 'SSDSCKKB480G8R', 480103981056);
INSERT INTO public.drive_model VALUES (86, 1, 'ST2000DL003', 2000398934016);
INSERT INTO public.drive_model VALUES (87, 1, 'WDC WD10EACS', 1000204886016);
INSERT INTO public.drive_model VALUES (88, 1, 'ST16000NM000G', 16000900661248);
INSERT INTO public.drive_model VALUES (89, 1, ' 00MD00', 4000787030016);
INSERT INTO public.drive_model VALUES (90, 1, 'Hitachi HDS5C3030BLE630', 3000592982016);
INSERT INTO public.drive_model VALUES (91, 1, 'WDC WD2500JB', 250059350016);
INSERT INTO public.drive_model VALUES (92, 1, 'Hitachi HDT721010SLA360', 1000204886016);
INSERT INTO public.drive_model VALUES (93, 1, 'WDC WD800AAJS', 80026361856);
INSERT INTO public.drive_model VALUES (94, 1, 'ST6000DM001', 6001180000000);
INSERT INTO public.drive_model VALUES (95, 1, 'TOSHIBA MG11ACA24TE', 24000277250048);
INSERT INTO public.drive_model VALUES (96, 1, 'SAMSUNG HD154UI', 1500301910016);
INSERT INTO public.drive_model VALUES (97, 1, 'ST14000NM001G', 14000519643136);
INSERT INTO public.drive_model VALUES (98, 1, 'TOSHIBA MG10ACA20TE', 20000588955648);
INSERT INTO public.drive_model VALUES (99, 1, 'HGST HUS726040ALN610', 4000787030016);
INSERT INTO public.drive_model VALUES (100, 1, 'WDC WD10EARX', 1000204886016);
INSERT INTO public.drive_model VALUES (101, 1, 'TOSHIBA MG07ACA14TA', 14000519643136);
INSERT INTO public.drive_model VALUES (102, 1, 'CT250MX500SSD1', 250059350016);
INSERT INTO public.drive_model VALUES (103, 1, 'WD Blue SA510 2.5 250GB', 250059350016);
INSERT INTO public.drive_model VALUES (104, 1, 'Seagate IronWolf ZA250NM10002', 250059350016);
INSERT INTO public.drive_model VALUES (105, 1, 'ST12000NM0117', 12000138625024);
INSERT INTO public.drive_model VALUES (106, 1, 'ST14000NM0018', 14000519643136);
INSERT INTO public.drive_model VALUES (107, 1, 'Micron 5300 MTFDDAK480TDS', 480103981056);
INSERT INTO public.drive_model VALUES (108, 1, 'ST14000NM000J', 14000519643136);
INSERT INTO public.drive_model VALUES (109, 1, 'ST6000DX000', 6001180000000);
INSERT INTO public.drive_model VALUES (110, 1, 'ST2000DM001', 2000398934016);
INSERT INTO public.drive_model VALUES (111, 1, 'Hitachi HDS5C4040ALE630', 4000790000000);
INSERT INTO public.drive_model VALUES (112, 1, 'WDC WD800JD', 80026361856);
INSERT INTO public.drive_model VALUES (113, 1, 'WDC WD1600BPVT', 160042000000);
INSERT INTO public.drive_model VALUES (114, 1, 'ST31500541AS', 1500301910016);
INSERT INTO public.drive_model VALUES (115, 1, 'ST12000NM000J', 12000138625024);
INSERT INTO public.drive_model VALUES (116, 1, 'TOSHIBA DT01ACA300', 3000592982016);
INSERT INTO public.drive_model VALUES (117, 1, 'TOSHIBA MG08ACA16TA', 16000900661248);
INSERT INTO public.drive_model VALUES (118, 1, 'WDC WD10EADS', 1000204886016);
INSERT INTO public.drive_model VALUES (119, 1, 'Seagate BarraCuda SSD ZA2000CM10002', 2000398934016);
INSERT INTO public.drive_model VALUES (120, 1, 'WUH721816ALE6L4', 16000900661248);
INSERT INTO public.drive_model VALUES (121, 1, 'WDC WD10EALS', 1000204886016);
INSERT INTO public.drive_model VALUES (122, 1, 'TOSHIBA HDWF180', 8001563222016);
INSERT INTO public.drive_model VALUES (123, 1, 'WDC WD800JB', 80026361856);
INSERT INTO public.drive_model VALUES (124, 1, 'TOSHIBA MG09ACA16TE', 16000900661248);
INSERT INTO public.drive_model VALUES (125, 1, 'ST16000NM000J', 16000900661248);
INSERT INTO public.drive_model VALUES (126, 1, 'WDC WD40EFRX', 4000790000000);
INSERT INTO public.drive_model VALUES (127, 1, 'Hitachi HDS722020ALA330', 2000400000000);
INSERT INTO public.drive_model VALUES (128, 1, 'WDC WUH722222ALE6L4', 22000969973760);
INSERT INTO public.drive_model VALUES (129, 1, 'ST1500DM003', 1500301910016);
INSERT INTO public.drive_model VALUES (130, 1, 'WDC WD5003ABYX', 500107862016);
INSERT INTO public.drive_model VALUES (131, 1, 'ST4000DM001', 4000790000000);
INSERT INTO public.drive_model VALUES (132, 1, 'WDC WD10EADX', 1000204886016);
INSERT INTO public.drive_model VALUES (133, 1, 'ST8000DM004', 8001563222016);
INSERT INTO public.drive_model VALUES (134, 1, 'ST500LM021', 500107862016);
INSERT INTO public.drive_model VALUES (135, 1, 'HP SSD S700 250GB', 250059350016);
INSERT INTO public.drive_model VALUES (136, 1, 'WDC WD800AAJB', 80026361856);
INSERT INTO public.drive_model VALUES (137, 1, 'WDC WD30EZRX', 3000592982016);
INSERT INTO public.drive_model VALUES (138, 1, 'ST320LT007', 320073000000);
INSERT INTO public.drive_model VALUES (139, 1, 'ST10000NM0086', 10000831348736);
INSERT INTO public.drive_model VALUES (140, 1, 'WDC WD20EFRX', 2000398934016);
INSERT INTO public.drive_model VALUES (141, 1, 'Seagate BarraCuda SSD ZA500CM10002', 500107862016);
INSERT INTO public.drive_model VALUES (142, 1, 'ST4000DX000', 4000787030016);
INSERT INTO public.drive_model VALUES (143, 1, 'ST12000NM0007', 12000138625024);
INSERT INTO public.drive_model VALUES (144, 1, 'WDC WD5000LPCX', 500108000000);
INSERT INTO public.drive_model VALUES (145, 1, 'ST250LT007', 250059350016);
INSERT INTO public.drive_model VALUES (146, 1, 'WDC WD800LB', 80026361856);
INSERT INTO public.drive_model VALUES (147, 1, 'TOSHIBA MG08ACA16TE', 16000900661248);
INSERT INTO public.drive_model VALUES (148, 1, 'ST500LM030', 500107862016);
INSERT INTO public.drive_model VALUES (149, 1, 'WDC WD10EARS', 1000204886016);
INSERT INTO public.drive_model VALUES (150, 1, 'ST8000DM005', 8001563222016);
INSERT INTO public.drive_model VALUES (151, 1, 'HGST HMS5C4040ALE640', 107349320986927104);
INSERT INTO public.drive_model VALUES (152, 1, 'ST14000NM002J', 14000519643136);
INSERT INTO public.drive_model VALUES (153, 1, 'WDC WD2500AAJB', 250059350016);
INSERT INTO public.drive_model VALUES (154, 1, 'ST32000542AS', 2000398934016);
INSERT INTO public.drive_model VALUES (155, 1, 'WDC WD3200BEKT', 320072933376);
INSERT INTO public.drive_model VALUES (156, 1, 'ST1500DL003', 1500301910016);
INSERT INTO public.drive_model VALUES (157, 1, 'ST3160318AS', 160042000000);
INSERT INTO public.drive_model VALUES (158, 1, 'HGST HDS724040ALE640', 4000790000000);
INSERT INTO public.drive_model VALUES (159, 1, 'HGST HUH721212ALE604', 12000138625024);
INSERT INTO public.drive_model VALUES (160, 1, 'ST16000NM002J', 16000900661248);
INSERT INTO public.drive_model VALUES (161, 1, 'Samsung SSD 850 EVO 1TB', 1000204886016);
INSERT INTO public.drive_model VALUES (162, 1, 'ST3160316AS', 160042000000);
INSERT INTO public.drive_model VALUES (163, 1, 'WDC WUH722626ALE6L4', 26000658268160);
INSERT INTO public.drive_model VALUES (164, 1, 'HGST HUS728T8TALE6L4', 8001563222016);
INSERT INTO public.drive_model VALUES (165, 1, 'WDC WUH721816ALE6L4', 16000900661248);
INSERT INTO public.drive_model VALUES (166, 1, 'Hitachi HDS723020BLA642', 2000398934016);
INSERT INTO public.drive_model VALUES (167, 1, 'ST250LM004 HN', 250059350016);
INSERT INTO public.drive_model VALUES (168, 1, 'TOSHIBA MG08ACA16TEY', 16000900661248);
INSERT INTO public.drive_model VALUES (169, 1, 'Samsung SSD 850 PRO 1TB', 1024209543168);
INSERT INTO public.drive_model VALUES (170, 1, 'ST12000NM0008', 12000138625024);
INSERT INTO public.drive_model VALUES (171, 1, 'ST9320325AS', 320073000000);
INSERT INTO public.drive_model VALUES (172, 1, 'Seagate FireCuda 120 SSD ZA500GM10001', 500107862016);
INSERT INTO public.drive_model VALUES (173, 1, 'WDC WD3200AAJB', 320072933376);
INSERT INTO public.drive_model VALUES (174, 1, 'ST16000NM005G', 16000900661248);
INSERT INTO public.drive_model VALUES (175, 1, 'ST1500DL001', 1500301910016);
INSERT INTO public.drive_model VALUES (176, 1, 'WDC  WUH721816ALE6L4', 16000900661248);
INSERT INTO public.drive_model VALUES (177, 1, 'MTFDDAV480TCB', 480103981056);


--
-- TOC entry 4819 (class 0 OID 29472)
-- Dependencies: 281
-- Data for Name: ingest_batch; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- TOC entry 4821 (class 0 OID 29490)
-- Dependencies: 283
-- Data for Name: manufacturer; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.manufacturer VALUES (1, 'Unknown');


--
-- TOC entry 4817 (class 0 OID 29459)
-- Dependencies: 279
-- Data for Name: provider; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.provider VALUES (1, 'backblaze');


--
-- TOC entry 4904 (class 0 OID 0)
-- Dependencies: 286
-- Name: drive_drive_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.drive_drive_id_seq', 2237473, true);


--
-- TOC entry 4905 (class 0 OID 0)
-- Dependencies: 284
-- Name: drive_model_model_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.drive_model_model_id_seq', 177, true);


--
-- TOC entry 4906 (class 0 OID 0)
-- Dependencies: 280
-- Name: ingest_batch_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.ingest_batch_batch_id_seq', 1, true);


--
-- TOC entry 4907 (class 0 OID 0)
-- Dependencies: 282
-- Name: manufacturer_manufacturer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.manufacturer_manufacturer_id_seq', 1, true);


--
-- TOC entry 4908 (class 0 OID 0)
-- Dependencies: 278
-- Name: provider_provider_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.provider_provider_id_seq', 1, true);


--
-- TOC entry 4476 (class 2606 OID 36090)
-- Name: drive_day_load_log drive_day_load_log_pkey; Type: CONSTRAINT; Schema: bb; Owner: -
--

ALTER TABLE ONLY bb.drive_day_load_log
    ADD CONSTRAINT drive_day_load_log_pkey PRIMARY KEY (batch_id, year, quarter);


--
-- TOC entry 4130 (class 2606 OID 24585)
-- Name: ingest_log ingest_log_pkey; Type: CONSTRAINT; Schema: bb; Owner: -
--

ALTER TABLE ONLY bb.ingest_log
    ADD CONSTRAINT ingest_log_pkey PRIMARY KEY (path);


--
-- TOC entry 4199 (class 2606 OID 29619)
-- Name: drive_day_2013_q1 drive_day_2013_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q1
    ADD CONSTRAINT drive_day_2013_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4204 (class 2606 OID 29638)
-- Name: drive_day_2013_q2 drive_day_2013_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q2
    ADD CONSTRAINT drive_day_2013_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4209 (class 2606 OID 29657)
-- Name: drive_day_2013_q3 drive_day_2013_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q3
    ADD CONSTRAINT drive_day_2013_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4214 (class 2606 OID 29676)
-- Name: drive_day_2013_q4 drive_day_2013_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q4
    ADD CONSTRAINT drive_day_2013_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4219 (class 2606 OID 29695)
-- Name: drive_day_2014_q1 drive_day_2014_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q1
    ADD CONSTRAINT drive_day_2014_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4224 (class 2606 OID 29714)
-- Name: drive_day_2014_q2 drive_day_2014_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q2
    ADD CONSTRAINT drive_day_2014_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4229 (class 2606 OID 29733)
-- Name: drive_day_2014_q3 drive_day_2014_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q3
    ADD CONSTRAINT drive_day_2014_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4234 (class 2606 OID 29752)
-- Name: drive_day_2014_q4 drive_day_2014_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q4
    ADD CONSTRAINT drive_day_2014_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4239 (class 2606 OID 29771)
-- Name: drive_day_2015_q1 drive_day_2015_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q1
    ADD CONSTRAINT drive_day_2015_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4244 (class 2606 OID 29790)
-- Name: drive_day_2015_q2 drive_day_2015_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q2
    ADD CONSTRAINT drive_day_2015_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4249 (class 2606 OID 29809)
-- Name: drive_day_2015_q3 drive_day_2015_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q3
    ADD CONSTRAINT drive_day_2015_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4254 (class 2606 OID 29828)
-- Name: drive_day_2015_q4 drive_day_2015_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q4
    ADD CONSTRAINT drive_day_2015_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4259 (class 2606 OID 29847)
-- Name: drive_day_2016_q1 drive_day_2016_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q1
    ADD CONSTRAINT drive_day_2016_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4264 (class 2606 OID 29866)
-- Name: drive_day_2016_q2 drive_day_2016_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q2
    ADD CONSTRAINT drive_day_2016_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4269 (class 2606 OID 29885)
-- Name: drive_day_2016_q3 drive_day_2016_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q3
    ADD CONSTRAINT drive_day_2016_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4274 (class 2606 OID 29904)
-- Name: drive_day_2016_q4 drive_day_2016_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q4
    ADD CONSTRAINT drive_day_2016_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4279 (class 2606 OID 29923)
-- Name: drive_day_2017_q1 drive_day_2017_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q1
    ADD CONSTRAINT drive_day_2017_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4284 (class 2606 OID 29942)
-- Name: drive_day_2017_q2 drive_day_2017_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q2
    ADD CONSTRAINT drive_day_2017_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4289 (class 2606 OID 29961)
-- Name: drive_day_2017_q3 drive_day_2017_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q3
    ADD CONSTRAINT drive_day_2017_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4294 (class 2606 OID 29980)
-- Name: drive_day_2017_q4 drive_day_2017_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q4
    ADD CONSTRAINT drive_day_2017_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4299 (class 2606 OID 29999)
-- Name: drive_day_2018_q1 drive_day_2018_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q1
    ADD CONSTRAINT drive_day_2018_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4304 (class 2606 OID 30018)
-- Name: drive_day_2018_q2 drive_day_2018_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q2
    ADD CONSTRAINT drive_day_2018_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4309 (class 2606 OID 30037)
-- Name: drive_day_2018_q3 drive_day_2018_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q3
    ADD CONSTRAINT drive_day_2018_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4314 (class 2606 OID 30056)
-- Name: drive_day_2018_q4 drive_day_2018_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q4
    ADD CONSTRAINT drive_day_2018_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4319 (class 2606 OID 30075)
-- Name: drive_day_2019_q1 drive_day_2019_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q1
    ADD CONSTRAINT drive_day_2019_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4324 (class 2606 OID 30094)
-- Name: drive_day_2019_q2 drive_day_2019_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q2
    ADD CONSTRAINT drive_day_2019_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4329 (class 2606 OID 30113)
-- Name: drive_day_2019_q3 drive_day_2019_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q3
    ADD CONSTRAINT drive_day_2019_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4334 (class 2606 OID 30132)
-- Name: drive_day_2019_q4 drive_day_2019_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q4
    ADD CONSTRAINT drive_day_2019_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4339 (class 2606 OID 30151)
-- Name: drive_day_2020_q1 drive_day_2020_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q1
    ADD CONSTRAINT drive_day_2020_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4344 (class 2606 OID 30170)
-- Name: drive_day_2020_q2 drive_day_2020_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q2
    ADD CONSTRAINT drive_day_2020_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4349 (class 2606 OID 30189)
-- Name: drive_day_2020_q3 drive_day_2020_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q3
    ADD CONSTRAINT drive_day_2020_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4354 (class 2606 OID 30208)
-- Name: drive_day_2020_q4 drive_day_2020_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q4
    ADD CONSTRAINT drive_day_2020_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4359 (class 2606 OID 30227)
-- Name: drive_day_2021_q1 drive_day_2021_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q1
    ADD CONSTRAINT drive_day_2021_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4364 (class 2606 OID 30246)
-- Name: drive_day_2021_q2 drive_day_2021_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q2
    ADD CONSTRAINT drive_day_2021_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4369 (class 2606 OID 30265)
-- Name: drive_day_2021_q3 drive_day_2021_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q3
    ADD CONSTRAINT drive_day_2021_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4374 (class 2606 OID 30284)
-- Name: drive_day_2021_q4 drive_day_2021_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q4
    ADD CONSTRAINT drive_day_2021_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4379 (class 2606 OID 30303)
-- Name: drive_day_2022_q1 drive_day_2022_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q1
    ADD CONSTRAINT drive_day_2022_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4384 (class 2606 OID 30322)
-- Name: drive_day_2022_q2 drive_day_2022_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q2
    ADD CONSTRAINT drive_day_2022_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4389 (class 2606 OID 30341)
-- Name: drive_day_2022_q3 drive_day_2022_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q3
    ADD CONSTRAINT drive_day_2022_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4394 (class 2606 OID 30360)
-- Name: drive_day_2022_q4 drive_day_2022_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q4
    ADD CONSTRAINT drive_day_2022_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4399 (class 2606 OID 30379)
-- Name: drive_day_2023_q1 drive_day_2023_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q1
    ADD CONSTRAINT drive_day_2023_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4404 (class 2606 OID 30398)
-- Name: drive_day_2023_q2 drive_day_2023_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q2
    ADD CONSTRAINT drive_day_2023_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4409 (class 2606 OID 30417)
-- Name: drive_day_2023_q3 drive_day_2023_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q3
    ADD CONSTRAINT drive_day_2023_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4414 (class 2606 OID 30436)
-- Name: drive_day_2023_q4 drive_day_2023_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q4
    ADD CONSTRAINT drive_day_2023_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4419 (class 2606 OID 30455)
-- Name: drive_day_2024_q1 drive_day_2024_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q1
    ADD CONSTRAINT drive_day_2024_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4424 (class 2606 OID 30474)
-- Name: drive_day_2024_q2 drive_day_2024_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q2
    ADD CONSTRAINT drive_day_2024_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4429 (class 2606 OID 30493)
-- Name: drive_day_2024_q3 drive_day_2024_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q3
    ADD CONSTRAINT drive_day_2024_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4434 (class 2606 OID 30512)
-- Name: drive_day_2024_q4 drive_day_2024_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q4
    ADD CONSTRAINT drive_day_2024_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4439 (class 2606 OID 30531)
-- Name: drive_day_2025_q1 drive_day_2025_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q1
    ADD CONSTRAINT drive_day_2025_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4444 (class 2606 OID 30550)
-- Name: drive_day_2025_q2 drive_day_2025_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q2
    ADD CONSTRAINT drive_day_2025_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4449 (class 2606 OID 30569)
-- Name: drive_day_2025_q3 drive_day_2025_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q3
    ADD CONSTRAINT drive_day_2025_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4454 (class 2606 OID 30588)
-- Name: drive_day_2025_q4 drive_day_2025_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q4
    ADD CONSTRAINT drive_day_2025_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4459 (class 2606 OID 30607)
-- Name: drive_day_2026_q1 drive_day_2026_q1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q1
    ADD CONSTRAINT drive_day_2026_q1_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4464 (class 2606 OID 30626)
-- Name: drive_day_2026_q2 drive_day_2026_q2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q2
    ADD CONSTRAINT drive_day_2026_q2_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4469 (class 2606 OID 30645)
-- Name: drive_day_2026_q3 drive_day_2026_q3_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q3
    ADD CONSTRAINT drive_day_2026_q3_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4474 (class 2606 OID 30664)
-- Name: drive_day_2026_q4 drive_day_2026_q4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q4
    ADD CONSTRAINT drive_day_2026_q4_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4194 (class 2606 OID 29601)
-- Name: drive_day drive_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day
    ADD CONSTRAINT drive_day_pkey PRIMARY KEY (provider_id, drive_id, date);


--
-- TOC entry 4180 (class 2606 OID 29514)
-- Name: drive_model drive_model_model_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_model
    ADD CONSTRAINT drive_model_model_name_key UNIQUE (model_name);


--
-- TOC entry 4183 (class 2606 OID 29512)
-- Name: drive_model drive_model_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_model
    ADD CONSTRAINT drive_model_pkey PRIMARY KEY (model_id);


--
-- TOC entry 4185 (class 2606 OID 29532)
-- Name: drive drive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive
    ADD CONSTRAINT drive_pkey PRIMARY KEY (drive_id);


--
-- TOC entry 4187 (class 2606 OID 29534)
-- Name: drive drive_provider_id_model_id_serial_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive
    ADD CONSTRAINT drive_provider_id_model_id_serial_number_key UNIQUE (provider_id, model_id, serial_number);


--
-- TOC entry 4172 (class 2606 OID 29483)
-- Name: ingest_batch ingest_batch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingest_batch
    ADD CONSTRAINT ingest_batch_pkey PRIMARY KEY (batch_id);


--
-- TOC entry 4174 (class 2606 OID 29501)
-- Name: manufacturer manufacturer_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manufacturer
    ADD CONSTRAINT manufacturer_name_key UNIQUE (name);


--
-- TOC entry 4176 (class 2606 OID 29499)
-- Name: manufacturer manufacturer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manufacturer
    ADD CONSTRAINT manufacturer_pkey PRIMARY KEY (manufacturer_id);


--
-- TOC entry 4168 (class 2606 OID 29470)
-- Name: provider provider_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider
    ADD CONSTRAINT provider_name_key UNIQUE (name);


--
-- TOC entry 4170 (class 2606 OID 29468)
-- Name: provider provider_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider
    ADD CONSTRAINT provider_pkey PRIMARY KEY (provider_id);


--
-- TOC entry 4477 (class 1259 OID 36096)
-- Name: drive_day_load_log_status_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_day_load_log_status_idx ON bb.drive_day_load_log USING btree (status) WITH (fillfactor='100', deduplicate_items='true');


--
-- TOC entry 4131 (class 1259 OID 36860)
-- Name: drive_stats_raw_2013_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q1_date_idx ON bb.drive_stats_raw_2013_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4132 (class 1259 OID 36917)
-- Name: drive_stats_raw_2013_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q1_model_date_idx ON bb.drive_stats_raw_2013_q1 USING btree (model, date);


--
-- TOC entry 4133 (class 1259 OID 36974)
-- Name: drive_stats_raw_2013_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q1_serial_number_date_idx ON bb.drive_stats_raw_2013_q1 USING btree (serial_number, date);


--
-- TOC entry 4134 (class 1259 OID 36861)
-- Name: drive_stats_raw_2013_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q2_date_idx ON bb.drive_stats_raw_2013_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4135 (class 1259 OID 36918)
-- Name: drive_stats_raw_2013_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q2_model_date_idx ON bb.drive_stats_raw_2013_q2 USING btree (model, date);


--
-- TOC entry 4136 (class 1259 OID 36975)
-- Name: drive_stats_raw_2013_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q2_serial_number_date_idx ON bb.drive_stats_raw_2013_q2 USING btree (serial_number, date);


--
-- TOC entry 4137 (class 1259 OID 36862)
-- Name: drive_stats_raw_2013_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q3_date_idx ON bb.drive_stats_raw_2013_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4138 (class 1259 OID 36919)
-- Name: drive_stats_raw_2013_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q3_model_date_idx ON bb.drive_stats_raw_2013_q3 USING btree (model, date);


--
-- TOC entry 4139 (class 1259 OID 36976)
-- Name: drive_stats_raw_2013_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q3_serial_number_date_idx ON bb.drive_stats_raw_2013_q3 USING btree (serial_number, date);


--
-- TOC entry 4140 (class 1259 OID 36863)
-- Name: drive_stats_raw_2013_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q4_date_idx ON bb.drive_stats_raw_2013_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4141 (class 1259 OID 36920)
-- Name: drive_stats_raw_2013_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q4_model_date_idx ON bb.drive_stats_raw_2013_q4 USING btree (model, date);


--
-- TOC entry 4142 (class 1259 OID 36977)
-- Name: drive_stats_raw_2013_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2013_q4_serial_number_date_idx ON bb.drive_stats_raw_2013_q4 USING btree (serial_number, date);


--
-- TOC entry 4143 (class 1259 OID 36864)
-- Name: drive_stats_raw_2014_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q1_date_idx ON bb.drive_stats_raw_2014_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4144 (class 1259 OID 36921)
-- Name: drive_stats_raw_2014_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q1_model_date_idx ON bb.drive_stats_raw_2014_q1 USING btree (model, date);


--
-- TOC entry 4145 (class 1259 OID 36978)
-- Name: drive_stats_raw_2014_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q1_serial_number_date_idx ON bb.drive_stats_raw_2014_q1 USING btree (serial_number, date);


--
-- TOC entry 4146 (class 1259 OID 36865)
-- Name: drive_stats_raw_2014_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q2_date_idx ON bb.drive_stats_raw_2014_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4147 (class 1259 OID 36922)
-- Name: drive_stats_raw_2014_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q2_model_date_idx ON bb.drive_stats_raw_2014_q2 USING btree (model, date);


--
-- TOC entry 4148 (class 1259 OID 36979)
-- Name: drive_stats_raw_2014_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q2_serial_number_date_idx ON bb.drive_stats_raw_2014_q2 USING btree (serial_number, date);


--
-- TOC entry 4149 (class 1259 OID 36866)
-- Name: drive_stats_raw_2014_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q3_date_idx ON bb.drive_stats_raw_2014_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4150 (class 1259 OID 36923)
-- Name: drive_stats_raw_2014_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q3_model_date_idx ON bb.drive_stats_raw_2014_q3 USING btree (model, date);


--
-- TOC entry 4151 (class 1259 OID 36980)
-- Name: drive_stats_raw_2014_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q3_serial_number_date_idx ON bb.drive_stats_raw_2014_q3 USING btree (serial_number, date);


--
-- TOC entry 4152 (class 1259 OID 36867)
-- Name: drive_stats_raw_2014_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q4_date_idx ON bb.drive_stats_raw_2014_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4153 (class 1259 OID 36924)
-- Name: drive_stats_raw_2014_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q4_model_date_idx ON bb.drive_stats_raw_2014_q4 USING btree (model, date);


--
-- TOC entry 4154 (class 1259 OID 36981)
-- Name: drive_stats_raw_2014_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2014_q4_serial_number_date_idx ON bb.drive_stats_raw_2014_q4 USING btree (serial_number, date);


--
-- TOC entry 4155 (class 1259 OID 36868)
-- Name: drive_stats_raw_2015_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q1_date_idx ON bb.drive_stats_raw_2015_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4156 (class 1259 OID 36925)
-- Name: drive_stats_raw_2015_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q1_model_date_idx ON bb.drive_stats_raw_2015_q1 USING btree (model, date);


--
-- TOC entry 4157 (class 1259 OID 36982)
-- Name: drive_stats_raw_2015_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q1_serial_number_date_idx ON bb.drive_stats_raw_2015_q1 USING btree (serial_number, date);


--
-- TOC entry 4158 (class 1259 OID 36869)
-- Name: drive_stats_raw_2015_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q2_date_idx ON bb.drive_stats_raw_2015_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4159 (class 1259 OID 36926)
-- Name: drive_stats_raw_2015_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q2_model_date_idx ON bb.drive_stats_raw_2015_q2 USING btree (model, date);


--
-- TOC entry 4160 (class 1259 OID 36983)
-- Name: drive_stats_raw_2015_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q2_serial_number_date_idx ON bb.drive_stats_raw_2015_q2 USING btree (serial_number, date);


--
-- TOC entry 4161 (class 1259 OID 36870)
-- Name: drive_stats_raw_2015_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q3_date_idx ON bb.drive_stats_raw_2015_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4162 (class 1259 OID 36927)
-- Name: drive_stats_raw_2015_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q3_model_date_idx ON bb.drive_stats_raw_2015_q3 USING btree (model, date);


--
-- TOC entry 4163 (class 1259 OID 36984)
-- Name: drive_stats_raw_2015_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q3_serial_number_date_idx ON bb.drive_stats_raw_2015_q3 USING btree (serial_number, date);


--
-- TOC entry 4164 (class 1259 OID 36871)
-- Name: drive_stats_raw_2015_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q4_date_idx ON bb.drive_stats_raw_2015_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4165 (class 1259 OID 36928)
-- Name: drive_stats_raw_2015_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q4_model_date_idx ON bb.drive_stats_raw_2015_q4 USING btree (model, date);


--
-- TOC entry 4166 (class 1259 OID 36985)
-- Name: drive_stats_raw_2015_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2015_q4_serial_number_date_idx ON bb.drive_stats_raw_2015_q4 USING btree (serial_number, date);


--
-- TOC entry 3997 (class 1259 OID 36872)
-- Name: drive_stats_raw_2016_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q1_date_idx ON bb.drive_stats_raw_2016_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 3998 (class 1259 OID 36929)
-- Name: drive_stats_raw_2016_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q1_model_date_idx ON bb.drive_stats_raw_2016_q1 USING btree (model, date);


--
-- TOC entry 3999 (class 1259 OID 36986)
-- Name: drive_stats_raw_2016_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q1_serial_number_date_idx ON bb.drive_stats_raw_2016_q1 USING btree (serial_number, date);


--
-- TOC entry 4000 (class 1259 OID 36873)
-- Name: drive_stats_raw_2016_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q2_date_idx ON bb.drive_stats_raw_2016_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4001 (class 1259 OID 36930)
-- Name: drive_stats_raw_2016_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q2_model_date_idx ON bb.drive_stats_raw_2016_q2 USING btree (model, date);


--
-- TOC entry 4002 (class 1259 OID 36987)
-- Name: drive_stats_raw_2016_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q2_serial_number_date_idx ON bb.drive_stats_raw_2016_q2 USING btree (serial_number, date);


--
-- TOC entry 4003 (class 1259 OID 36874)
-- Name: drive_stats_raw_2016_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q3_date_idx ON bb.drive_stats_raw_2016_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4004 (class 1259 OID 36931)
-- Name: drive_stats_raw_2016_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q3_model_date_idx ON bb.drive_stats_raw_2016_q3 USING btree (model, date);


--
-- TOC entry 4005 (class 1259 OID 36988)
-- Name: drive_stats_raw_2016_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q3_serial_number_date_idx ON bb.drive_stats_raw_2016_q3 USING btree (serial_number, date);


--
-- TOC entry 4006 (class 1259 OID 36875)
-- Name: drive_stats_raw_2016_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q4_date_idx ON bb.drive_stats_raw_2016_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4007 (class 1259 OID 36932)
-- Name: drive_stats_raw_2016_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q4_model_date_idx ON bb.drive_stats_raw_2016_q4 USING btree (model, date);


--
-- TOC entry 4008 (class 1259 OID 36989)
-- Name: drive_stats_raw_2016_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2016_q4_serial_number_date_idx ON bb.drive_stats_raw_2016_q4 USING btree (serial_number, date);


--
-- TOC entry 4009 (class 1259 OID 36876)
-- Name: drive_stats_raw_2017_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q1_date_idx ON bb.drive_stats_raw_2017_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4010 (class 1259 OID 36933)
-- Name: drive_stats_raw_2017_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q1_model_date_idx ON bb.drive_stats_raw_2017_q1 USING btree (model, date);


--
-- TOC entry 4011 (class 1259 OID 36990)
-- Name: drive_stats_raw_2017_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q1_serial_number_date_idx ON bb.drive_stats_raw_2017_q1 USING btree (serial_number, date);


--
-- TOC entry 4012 (class 1259 OID 36877)
-- Name: drive_stats_raw_2017_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q2_date_idx ON bb.drive_stats_raw_2017_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4013 (class 1259 OID 36934)
-- Name: drive_stats_raw_2017_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q2_model_date_idx ON bb.drive_stats_raw_2017_q2 USING btree (model, date);


--
-- TOC entry 4014 (class 1259 OID 36991)
-- Name: drive_stats_raw_2017_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q2_serial_number_date_idx ON bb.drive_stats_raw_2017_q2 USING btree (serial_number, date);


--
-- TOC entry 4015 (class 1259 OID 36878)
-- Name: drive_stats_raw_2017_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q3_date_idx ON bb.drive_stats_raw_2017_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4016 (class 1259 OID 36935)
-- Name: drive_stats_raw_2017_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q3_model_date_idx ON bb.drive_stats_raw_2017_q3 USING btree (model, date);


--
-- TOC entry 4017 (class 1259 OID 36992)
-- Name: drive_stats_raw_2017_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q3_serial_number_date_idx ON bb.drive_stats_raw_2017_q3 USING btree (serial_number, date);


--
-- TOC entry 4018 (class 1259 OID 36879)
-- Name: drive_stats_raw_2017_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q4_date_idx ON bb.drive_stats_raw_2017_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4019 (class 1259 OID 36936)
-- Name: drive_stats_raw_2017_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q4_model_date_idx ON bb.drive_stats_raw_2017_q4 USING btree (model, date);


--
-- TOC entry 4020 (class 1259 OID 36993)
-- Name: drive_stats_raw_2017_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2017_q4_serial_number_date_idx ON bb.drive_stats_raw_2017_q4 USING btree (serial_number, date);


--
-- TOC entry 4021 (class 1259 OID 36880)
-- Name: drive_stats_raw_2018_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q1_date_idx ON bb.drive_stats_raw_2018_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4022 (class 1259 OID 36937)
-- Name: drive_stats_raw_2018_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q1_model_date_idx ON bb.drive_stats_raw_2018_q1 USING btree (model, date);


--
-- TOC entry 4023 (class 1259 OID 36994)
-- Name: drive_stats_raw_2018_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q1_serial_number_date_idx ON bb.drive_stats_raw_2018_q1 USING btree (serial_number, date);


--
-- TOC entry 4024 (class 1259 OID 36881)
-- Name: drive_stats_raw_2018_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q2_date_idx ON bb.drive_stats_raw_2018_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4025 (class 1259 OID 36938)
-- Name: drive_stats_raw_2018_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q2_model_date_idx ON bb.drive_stats_raw_2018_q2 USING btree (model, date);


--
-- TOC entry 4026 (class 1259 OID 36995)
-- Name: drive_stats_raw_2018_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q2_serial_number_date_idx ON bb.drive_stats_raw_2018_q2 USING btree (serial_number, date);


--
-- TOC entry 4027 (class 1259 OID 36882)
-- Name: drive_stats_raw_2018_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q3_date_idx ON bb.drive_stats_raw_2018_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4028 (class 1259 OID 36939)
-- Name: drive_stats_raw_2018_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q3_model_date_idx ON bb.drive_stats_raw_2018_q3 USING btree (model, date);


--
-- TOC entry 4029 (class 1259 OID 36996)
-- Name: drive_stats_raw_2018_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q3_serial_number_date_idx ON bb.drive_stats_raw_2018_q3 USING btree (serial_number, date);


--
-- TOC entry 4030 (class 1259 OID 36883)
-- Name: drive_stats_raw_2018_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q4_date_idx ON bb.drive_stats_raw_2018_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4031 (class 1259 OID 36940)
-- Name: drive_stats_raw_2018_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q4_model_date_idx ON bb.drive_stats_raw_2018_q4 USING btree (model, date);


--
-- TOC entry 4032 (class 1259 OID 36997)
-- Name: drive_stats_raw_2018_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2018_q4_serial_number_date_idx ON bb.drive_stats_raw_2018_q4 USING btree (serial_number, date);


--
-- TOC entry 4033 (class 1259 OID 36884)
-- Name: drive_stats_raw_2019_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q1_date_idx ON bb.drive_stats_raw_2019_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4034 (class 1259 OID 36941)
-- Name: drive_stats_raw_2019_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q1_model_date_idx ON bb.drive_stats_raw_2019_q1 USING btree (model, date);


--
-- TOC entry 4035 (class 1259 OID 36998)
-- Name: drive_stats_raw_2019_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q1_serial_number_date_idx ON bb.drive_stats_raw_2019_q1 USING btree (serial_number, date);


--
-- TOC entry 4036 (class 1259 OID 36885)
-- Name: drive_stats_raw_2019_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q2_date_idx ON bb.drive_stats_raw_2019_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4037 (class 1259 OID 36942)
-- Name: drive_stats_raw_2019_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q2_model_date_idx ON bb.drive_stats_raw_2019_q2 USING btree (model, date);


--
-- TOC entry 4038 (class 1259 OID 36999)
-- Name: drive_stats_raw_2019_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q2_serial_number_date_idx ON bb.drive_stats_raw_2019_q2 USING btree (serial_number, date);


--
-- TOC entry 4039 (class 1259 OID 36886)
-- Name: drive_stats_raw_2019_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q3_date_idx ON bb.drive_stats_raw_2019_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4040 (class 1259 OID 36943)
-- Name: drive_stats_raw_2019_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q3_model_date_idx ON bb.drive_stats_raw_2019_q3 USING btree (model, date);


--
-- TOC entry 4041 (class 1259 OID 37000)
-- Name: drive_stats_raw_2019_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q3_serial_number_date_idx ON bb.drive_stats_raw_2019_q3 USING btree (serial_number, date);


--
-- TOC entry 4042 (class 1259 OID 36887)
-- Name: drive_stats_raw_2019_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q4_date_idx ON bb.drive_stats_raw_2019_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4043 (class 1259 OID 36944)
-- Name: drive_stats_raw_2019_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q4_model_date_idx ON bb.drive_stats_raw_2019_q4 USING btree (model, date);


--
-- TOC entry 4044 (class 1259 OID 37001)
-- Name: drive_stats_raw_2019_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2019_q4_serial_number_date_idx ON bb.drive_stats_raw_2019_q4 USING btree (serial_number, date);


--
-- TOC entry 4045 (class 1259 OID 36888)
-- Name: drive_stats_raw_2020_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q1_date_idx ON bb.drive_stats_raw_2020_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4046 (class 1259 OID 36945)
-- Name: drive_stats_raw_2020_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q1_model_date_idx ON bb.drive_stats_raw_2020_q1 USING btree (model, date);


--
-- TOC entry 4047 (class 1259 OID 37002)
-- Name: drive_stats_raw_2020_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q1_serial_number_date_idx ON bb.drive_stats_raw_2020_q1 USING btree (serial_number, date);


--
-- TOC entry 4048 (class 1259 OID 36889)
-- Name: drive_stats_raw_2020_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q2_date_idx ON bb.drive_stats_raw_2020_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4049 (class 1259 OID 36946)
-- Name: drive_stats_raw_2020_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q2_model_date_idx ON bb.drive_stats_raw_2020_q2 USING btree (model, date);


--
-- TOC entry 4050 (class 1259 OID 37003)
-- Name: drive_stats_raw_2020_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q2_serial_number_date_idx ON bb.drive_stats_raw_2020_q2 USING btree (serial_number, date);


--
-- TOC entry 4051 (class 1259 OID 36890)
-- Name: drive_stats_raw_2020_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q3_date_idx ON bb.drive_stats_raw_2020_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4052 (class 1259 OID 36947)
-- Name: drive_stats_raw_2020_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q3_model_date_idx ON bb.drive_stats_raw_2020_q3 USING btree (model, date);


--
-- TOC entry 4053 (class 1259 OID 37004)
-- Name: drive_stats_raw_2020_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q3_serial_number_date_idx ON bb.drive_stats_raw_2020_q3 USING btree (serial_number, date);


--
-- TOC entry 4054 (class 1259 OID 36891)
-- Name: drive_stats_raw_2020_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q4_date_idx ON bb.drive_stats_raw_2020_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4055 (class 1259 OID 36948)
-- Name: drive_stats_raw_2020_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q4_model_date_idx ON bb.drive_stats_raw_2020_q4 USING btree (model, date);


--
-- TOC entry 4056 (class 1259 OID 37005)
-- Name: drive_stats_raw_2020_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2020_q4_serial_number_date_idx ON bb.drive_stats_raw_2020_q4 USING btree (serial_number, date);


--
-- TOC entry 4057 (class 1259 OID 36892)
-- Name: drive_stats_raw_2021_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q1_date_idx ON bb.drive_stats_raw_2021_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4058 (class 1259 OID 36949)
-- Name: drive_stats_raw_2021_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q1_model_date_idx ON bb.drive_stats_raw_2021_q1 USING btree (model, date);


--
-- TOC entry 4059 (class 1259 OID 37006)
-- Name: drive_stats_raw_2021_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q1_serial_number_date_idx ON bb.drive_stats_raw_2021_q1 USING btree (serial_number, date);


--
-- TOC entry 4060 (class 1259 OID 36893)
-- Name: drive_stats_raw_2021_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q2_date_idx ON bb.drive_stats_raw_2021_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4061 (class 1259 OID 36950)
-- Name: drive_stats_raw_2021_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q2_model_date_idx ON bb.drive_stats_raw_2021_q2 USING btree (model, date);


--
-- TOC entry 4062 (class 1259 OID 37007)
-- Name: drive_stats_raw_2021_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q2_serial_number_date_idx ON bb.drive_stats_raw_2021_q2 USING btree (serial_number, date);


--
-- TOC entry 4063 (class 1259 OID 36894)
-- Name: drive_stats_raw_2021_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q3_date_idx ON bb.drive_stats_raw_2021_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4064 (class 1259 OID 36951)
-- Name: drive_stats_raw_2021_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q3_model_date_idx ON bb.drive_stats_raw_2021_q3 USING btree (model, date);


--
-- TOC entry 4065 (class 1259 OID 37008)
-- Name: drive_stats_raw_2021_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q3_serial_number_date_idx ON bb.drive_stats_raw_2021_q3 USING btree (serial_number, date);


--
-- TOC entry 4066 (class 1259 OID 36895)
-- Name: drive_stats_raw_2021_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q4_date_idx ON bb.drive_stats_raw_2021_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4067 (class 1259 OID 36952)
-- Name: drive_stats_raw_2021_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q4_model_date_idx ON bb.drive_stats_raw_2021_q4 USING btree (model, date);


--
-- TOC entry 4068 (class 1259 OID 37009)
-- Name: drive_stats_raw_2021_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2021_q4_serial_number_date_idx ON bb.drive_stats_raw_2021_q4 USING btree (serial_number, date);


--
-- TOC entry 4069 (class 1259 OID 36896)
-- Name: drive_stats_raw_2022_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q1_date_idx ON bb.drive_stats_raw_2022_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4070 (class 1259 OID 36953)
-- Name: drive_stats_raw_2022_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q1_model_date_idx ON bb.drive_stats_raw_2022_q1 USING btree (model, date);


--
-- TOC entry 4071 (class 1259 OID 37010)
-- Name: drive_stats_raw_2022_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q1_serial_number_date_idx ON bb.drive_stats_raw_2022_q1 USING btree (serial_number, date);


--
-- TOC entry 4072 (class 1259 OID 36897)
-- Name: drive_stats_raw_2022_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q2_date_idx ON bb.drive_stats_raw_2022_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4073 (class 1259 OID 36954)
-- Name: drive_stats_raw_2022_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q2_model_date_idx ON bb.drive_stats_raw_2022_q2 USING btree (model, date);


--
-- TOC entry 4074 (class 1259 OID 37011)
-- Name: drive_stats_raw_2022_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q2_serial_number_date_idx ON bb.drive_stats_raw_2022_q2 USING btree (serial_number, date);


--
-- TOC entry 4075 (class 1259 OID 36898)
-- Name: drive_stats_raw_2022_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q3_date_idx ON bb.drive_stats_raw_2022_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4076 (class 1259 OID 36955)
-- Name: drive_stats_raw_2022_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q3_model_date_idx ON bb.drive_stats_raw_2022_q3 USING btree (model, date);


--
-- TOC entry 4077 (class 1259 OID 37012)
-- Name: drive_stats_raw_2022_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q3_serial_number_date_idx ON bb.drive_stats_raw_2022_q3 USING btree (serial_number, date);


--
-- TOC entry 4078 (class 1259 OID 36899)
-- Name: drive_stats_raw_2022_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q4_date_idx ON bb.drive_stats_raw_2022_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4079 (class 1259 OID 36956)
-- Name: drive_stats_raw_2022_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q4_model_date_idx ON bb.drive_stats_raw_2022_q4 USING btree (model, date);


--
-- TOC entry 4080 (class 1259 OID 37013)
-- Name: drive_stats_raw_2022_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2022_q4_serial_number_date_idx ON bb.drive_stats_raw_2022_q4 USING btree (serial_number, date);


--
-- TOC entry 4081 (class 1259 OID 36900)
-- Name: drive_stats_raw_2023_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q1_date_idx ON bb.drive_stats_raw_2023_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4082 (class 1259 OID 36957)
-- Name: drive_stats_raw_2023_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q1_model_date_idx ON bb.drive_stats_raw_2023_q1 USING btree (model, date);


--
-- TOC entry 4083 (class 1259 OID 37014)
-- Name: drive_stats_raw_2023_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q1_serial_number_date_idx ON bb.drive_stats_raw_2023_q1 USING btree (serial_number, date);


--
-- TOC entry 4084 (class 1259 OID 36901)
-- Name: drive_stats_raw_2023_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q2_date_idx ON bb.drive_stats_raw_2023_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4085 (class 1259 OID 36958)
-- Name: drive_stats_raw_2023_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q2_model_date_idx ON bb.drive_stats_raw_2023_q2 USING btree (model, date);


--
-- TOC entry 4086 (class 1259 OID 37015)
-- Name: drive_stats_raw_2023_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q2_serial_number_date_idx ON bb.drive_stats_raw_2023_q2 USING btree (serial_number, date);


--
-- TOC entry 4087 (class 1259 OID 36902)
-- Name: drive_stats_raw_2023_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q3_date_idx ON bb.drive_stats_raw_2023_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4088 (class 1259 OID 36959)
-- Name: drive_stats_raw_2023_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q3_model_date_idx ON bb.drive_stats_raw_2023_q3 USING btree (model, date);


--
-- TOC entry 4089 (class 1259 OID 37016)
-- Name: drive_stats_raw_2023_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q3_serial_number_date_idx ON bb.drive_stats_raw_2023_q3 USING btree (serial_number, date);


--
-- TOC entry 4090 (class 1259 OID 36903)
-- Name: drive_stats_raw_2023_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q4_date_idx ON bb.drive_stats_raw_2023_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4091 (class 1259 OID 36960)
-- Name: drive_stats_raw_2023_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q4_model_date_idx ON bb.drive_stats_raw_2023_q4 USING btree (model, date);


--
-- TOC entry 4092 (class 1259 OID 37017)
-- Name: drive_stats_raw_2023_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2023_q4_serial_number_date_idx ON bb.drive_stats_raw_2023_q4 USING btree (serial_number, date);


--
-- TOC entry 4093 (class 1259 OID 36904)
-- Name: drive_stats_raw_2024_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q1_date_idx ON bb.drive_stats_raw_2024_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4094 (class 1259 OID 36961)
-- Name: drive_stats_raw_2024_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q1_model_date_idx ON bb.drive_stats_raw_2024_q1 USING btree (model, date);


--
-- TOC entry 4095 (class 1259 OID 37018)
-- Name: drive_stats_raw_2024_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q1_serial_number_date_idx ON bb.drive_stats_raw_2024_q1 USING btree (serial_number, date);


--
-- TOC entry 4096 (class 1259 OID 36905)
-- Name: drive_stats_raw_2024_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q2_date_idx ON bb.drive_stats_raw_2024_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4097 (class 1259 OID 36962)
-- Name: drive_stats_raw_2024_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q2_model_date_idx ON bb.drive_stats_raw_2024_q2 USING btree (model, date);


--
-- TOC entry 4098 (class 1259 OID 37019)
-- Name: drive_stats_raw_2024_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q2_serial_number_date_idx ON bb.drive_stats_raw_2024_q2 USING btree (serial_number, date);


--
-- TOC entry 4099 (class 1259 OID 36906)
-- Name: drive_stats_raw_2024_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q3_date_idx ON bb.drive_stats_raw_2024_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4100 (class 1259 OID 36963)
-- Name: drive_stats_raw_2024_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q3_model_date_idx ON bb.drive_stats_raw_2024_q3 USING btree (model, date);


--
-- TOC entry 4101 (class 1259 OID 37020)
-- Name: drive_stats_raw_2024_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q3_serial_number_date_idx ON bb.drive_stats_raw_2024_q3 USING btree (serial_number, date);


--
-- TOC entry 4102 (class 1259 OID 36907)
-- Name: drive_stats_raw_2024_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q4_date_idx ON bb.drive_stats_raw_2024_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4103 (class 1259 OID 36964)
-- Name: drive_stats_raw_2024_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q4_model_date_idx ON bb.drive_stats_raw_2024_q4 USING btree (model, date);


--
-- TOC entry 4104 (class 1259 OID 37021)
-- Name: drive_stats_raw_2024_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2024_q4_serial_number_date_idx ON bb.drive_stats_raw_2024_q4 USING btree (serial_number, date);


--
-- TOC entry 4105 (class 1259 OID 36908)
-- Name: drive_stats_raw_2025_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q1_date_idx ON bb.drive_stats_raw_2025_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4106 (class 1259 OID 36965)
-- Name: drive_stats_raw_2025_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q1_model_date_idx ON bb.drive_stats_raw_2025_q1 USING btree (model, date);


--
-- TOC entry 4107 (class 1259 OID 37022)
-- Name: drive_stats_raw_2025_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q1_serial_number_date_idx ON bb.drive_stats_raw_2025_q1 USING btree (serial_number, date);


--
-- TOC entry 4108 (class 1259 OID 36909)
-- Name: drive_stats_raw_2025_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q2_date_idx ON bb.drive_stats_raw_2025_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4109 (class 1259 OID 36966)
-- Name: drive_stats_raw_2025_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q2_model_date_idx ON bb.drive_stats_raw_2025_q2 USING btree (model, date);


--
-- TOC entry 4110 (class 1259 OID 37023)
-- Name: drive_stats_raw_2025_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q2_serial_number_date_idx ON bb.drive_stats_raw_2025_q2 USING btree (serial_number, date);


--
-- TOC entry 4111 (class 1259 OID 36910)
-- Name: drive_stats_raw_2025_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q3_date_idx ON bb.drive_stats_raw_2025_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4112 (class 1259 OID 36967)
-- Name: drive_stats_raw_2025_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q3_model_date_idx ON bb.drive_stats_raw_2025_q3 USING btree (model, date);


--
-- TOC entry 4113 (class 1259 OID 37024)
-- Name: drive_stats_raw_2025_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q3_serial_number_date_idx ON bb.drive_stats_raw_2025_q3 USING btree (serial_number, date);


--
-- TOC entry 4114 (class 1259 OID 36911)
-- Name: drive_stats_raw_2025_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q4_date_idx ON bb.drive_stats_raw_2025_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4115 (class 1259 OID 36968)
-- Name: drive_stats_raw_2025_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q4_model_date_idx ON bb.drive_stats_raw_2025_q4 USING btree (model, date);


--
-- TOC entry 4116 (class 1259 OID 37025)
-- Name: drive_stats_raw_2025_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2025_q4_serial_number_date_idx ON bb.drive_stats_raw_2025_q4 USING btree (serial_number, date);


--
-- TOC entry 4117 (class 1259 OID 36912)
-- Name: drive_stats_raw_2026_q1_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q1_date_idx ON bb.drive_stats_raw_2026_q1 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4118 (class 1259 OID 36969)
-- Name: drive_stats_raw_2026_q1_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q1_model_date_idx ON bb.drive_stats_raw_2026_q1 USING btree (model, date);


--
-- TOC entry 4119 (class 1259 OID 37026)
-- Name: drive_stats_raw_2026_q1_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q1_serial_number_date_idx ON bb.drive_stats_raw_2026_q1 USING btree (serial_number, date);


--
-- TOC entry 4120 (class 1259 OID 36913)
-- Name: drive_stats_raw_2026_q2_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q2_date_idx ON bb.drive_stats_raw_2026_q2 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4121 (class 1259 OID 36970)
-- Name: drive_stats_raw_2026_q2_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q2_model_date_idx ON bb.drive_stats_raw_2026_q2 USING btree (model, date);


--
-- TOC entry 4122 (class 1259 OID 37027)
-- Name: drive_stats_raw_2026_q2_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q2_serial_number_date_idx ON bb.drive_stats_raw_2026_q2 USING btree (serial_number, date);


--
-- TOC entry 4123 (class 1259 OID 36914)
-- Name: drive_stats_raw_2026_q3_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q3_date_idx ON bb.drive_stats_raw_2026_q3 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4124 (class 1259 OID 36971)
-- Name: drive_stats_raw_2026_q3_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q3_model_date_idx ON bb.drive_stats_raw_2026_q3 USING btree (model, date);


--
-- TOC entry 4125 (class 1259 OID 37028)
-- Name: drive_stats_raw_2026_q3_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q3_serial_number_date_idx ON bb.drive_stats_raw_2026_q3 USING btree (serial_number, date);


--
-- TOC entry 4126 (class 1259 OID 36915)
-- Name: drive_stats_raw_2026_q4_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q4_date_idx ON bb.drive_stats_raw_2026_q4 USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 4127 (class 1259 OID 36972)
-- Name: drive_stats_raw_2026_q4_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q4_model_date_idx ON bb.drive_stats_raw_2026_q4 USING btree (model, date);


--
-- TOC entry 4128 (class 1259 OID 37029)
-- Name: drive_stats_raw_2026_q4_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_2026_q4_serial_number_date_idx ON bb.drive_stats_raw_2026_q4 USING btree (serial_number, date);


--
-- TOC entry 3994 (class 1259 OID 36859)
-- Name: drive_stats_raw_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_date_idx ON ONLY bb.drive_stats_raw USING brin (date) WITH (pages_per_range='128', autosummarize='true');


--
-- TOC entry 3995 (class 1259 OID 36916)
-- Name: drive_stats_raw_model_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_model_date_idx ON ONLY bb.drive_stats_raw USING btree (model, date);


--
-- TOC entry 3996 (class 1259 OID 36973)
-- Name: drive_stats_raw_serial_number_date_idx; Type: INDEX; Schema: bb; Owner: -
--

CREATE INDEX drive_stats_raw_serial_number_date_idx ON ONLY bb.drive_stats_raw USING btree (serial_number, date);


--
-- TOC entry 4195 (class 1259 OID 36689)
-- Name: drive_day_2013_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q1_date_idx ON public.drive_day_2013_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4196 (class 1259 OID 36803)
-- Name: drive_day_2013_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q1_date_idx1 ON public.drive_day_2013_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4197 (class 1259 OID 36746)
-- Name: drive_day_2013_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q1_drive_id_date_idx ON public.drive_day_2013_q1 USING btree (drive_id, date);


--
-- TOC entry 4200 (class 1259 OID 36690)
-- Name: drive_day_2013_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q2_date_idx ON public.drive_day_2013_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4201 (class 1259 OID 36804)
-- Name: drive_day_2013_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q2_date_idx1 ON public.drive_day_2013_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4202 (class 1259 OID 36747)
-- Name: drive_day_2013_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q2_drive_id_date_idx ON public.drive_day_2013_q2 USING btree (drive_id, date);


--
-- TOC entry 4205 (class 1259 OID 36691)
-- Name: drive_day_2013_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q3_date_idx ON public.drive_day_2013_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4206 (class 1259 OID 36805)
-- Name: drive_day_2013_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q3_date_idx1 ON public.drive_day_2013_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4207 (class 1259 OID 36748)
-- Name: drive_day_2013_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q3_drive_id_date_idx ON public.drive_day_2013_q3 USING btree (drive_id, date);


--
-- TOC entry 4210 (class 1259 OID 36692)
-- Name: drive_day_2013_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q4_date_idx ON public.drive_day_2013_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4211 (class 1259 OID 36806)
-- Name: drive_day_2013_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q4_date_idx1 ON public.drive_day_2013_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4212 (class 1259 OID 36749)
-- Name: drive_day_2013_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2013_q4_drive_id_date_idx ON public.drive_day_2013_q4 USING btree (drive_id, date);


--
-- TOC entry 4215 (class 1259 OID 36693)
-- Name: drive_day_2014_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q1_date_idx ON public.drive_day_2014_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4216 (class 1259 OID 36807)
-- Name: drive_day_2014_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q1_date_idx1 ON public.drive_day_2014_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4217 (class 1259 OID 36750)
-- Name: drive_day_2014_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q1_drive_id_date_idx ON public.drive_day_2014_q1 USING btree (drive_id, date);


--
-- TOC entry 4220 (class 1259 OID 36694)
-- Name: drive_day_2014_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q2_date_idx ON public.drive_day_2014_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4221 (class 1259 OID 36808)
-- Name: drive_day_2014_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q2_date_idx1 ON public.drive_day_2014_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4222 (class 1259 OID 36751)
-- Name: drive_day_2014_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q2_drive_id_date_idx ON public.drive_day_2014_q2 USING btree (drive_id, date);


--
-- TOC entry 4225 (class 1259 OID 36695)
-- Name: drive_day_2014_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q3_date_idx ON public.drive_day_2014_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4226 (class 1259 OID 36809)
-- Name: drive_day_2014_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q3_date_idx1 ON public.drive_day_2014_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4227 (class 1259 OID 36752)
-- Name: drive_day_2014_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q3_drive_id_date_idx ON public.drive_day_2014_q3 USING btree (drive_id, date);


--
-- TOC entry 4230 (class 1259 OID 36696)
-- Name: drive_day_2014_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q4_date_idx ON public.drive_day_2014_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4231 (class 1259 OID 36810)
-- Name: drive_day_2014_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q4_date_idx1 ON public.drive_day_2014_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4232 (class 1259 OID 36753)
-- Name: drive_day_2014_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2014_q4_drive_id_date_idx ON public.drive_day_2014_q4 USING btree (drive_id, date);


--
-- TOC entry 4235 (class 1259 OID 36697)
-- Name: drive_day_2015_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q1_date_idx ON public.drive_day_2015_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4236 (class 1259 OID 36811)
-- Name: drive_day_2015_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q1_date_idx1 ON public.drive_day_2015_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4237 (class 1259 OID 36754)
-- Name: drive_day_2015_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q1_drive_id_date_idx ON public.drive_day_2015_q1 USING btree (drive_id, date);


--
-- TOC entry 4240 (class 1259 OID 36698)
-- Name: drive_day_2015_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q2_date_idx ON public.drive_day_2015_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4241 (class 1259 OID 36812)
-- Name: drive_day_2015_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q2_date_idx1 ON public.drive_day_2015_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4242 (class 1259 OID 36755)
-- Name: drive_day_2015_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q2_drive_id_date_idx ON public.drive_day_2015_q2 USING btree (drive_id, date);


--
-- TOC entry 4245 (class 1259 OID 36699)
-- Name: drive_day_2015_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q3_date_idx ON public.drive_day_2015_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4246 (class 1259 OID 36813)
-- Name: drive_day_2015_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q3_date_idx1 ON public.drive_day_2015_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4247 (class 1259 OID 36756)
-- Name: drive_day_2015_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q3_drive_id_date_idx ON public.drive_day_2015_q3 USING btree (drive_id, date);


--
-- TOC entry 4250 (class 1259 OID 36700)
-- Name: drive_day_2015_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q4_date_idx ON public.drive_day_2015_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4251 (class 1259 OID 36814)
-- Name: drive_day_2015_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q4_date_idx1 ON public.drive_day_2015_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4252 (class 1259 OID 36757)
-- Name: drive_day_2015_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2015_q4_drive_id_date_idx ON public.drive_day_2015_q4 USING btree (drive_id, date);


--
-- TOC entry 4255 (class 1259 OID 36701)
-- Name: drive_day_2016_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q1_date_idx ON public.drive_day_2016_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4256 (class 1259 OID 36815)
-- Name: drive_day_2016_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q1_date_idx1 ON public.drive_day_2016_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4257 (class 1259 OID 36758)
-- Name: drive_day_2016_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q1_drive_id_date_idx ON public.drive_day_2016_q1 USING btree (drive_id, date);


--
-- TOC entry 4260 (class 1259 OID 36702)
-- Name: drive_day_2016_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q2_date_idx ON public.drive_day_2016_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4261 (class 1259 OID 36816)
-- Name: drive_day_2016_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q2_date_idx1 ON public.drive_day_2016_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4262 (class 1259 OID 36759)
-- Name: drive_day_2016_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q2_drive_id_date_idx ON public.drive_day_2016_q2 USING btree (drive_id, date);


--
-- TOC entry 4265 (class 1259 OID 36703)
-- Name: drive_day_2016_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q3_date_idx ON public.drive_day_2016_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4266 (class 1259 OID 36817)
-- Name: drive_day_2016_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q3_date_idx1 ON public.drive_day_2016_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4267 (class 1259 OID 36760)
-- Name: drive_day_2016_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q3_drive_id_date_idx ON public.drive_day_2016_q3 USING btree (drive_id, date);


--
-- TOC entry 4270 (class 1259 OID 36704)
-- Name: drive_day_2016_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q4_date_idx ON public.drive_day_2016_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4271 (class 1259 OID 36818)
-- Name: drive_day_2016_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q4_date_idx1 ON public.drive_day_2016_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4272 (class 1259 OID 36761)
-- Name: drive_day_2016_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2016_q4_drive_id_date_idx ON public.drive_day_2016_q4 USING btree (drive_id, date);


--
-- TOC entry 4275 (class 1259 OID 36705)
-- Name: drive_day_2017_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q1_date_idx ON public.drive_day_2017_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4276 (class 1259 OID 36819)
-- Name: drive_day_2017_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q1_date_idx1 ON public.drive_day_2017_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4277 (class 1259 OID 36762)
-- Name: drive_day_2017_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q1_drive_id_date_idx ON public.drive_day_2017_q1 USING btree (drive_id, date);


--
-- TOC entry 4280 (class 1259 OID 36706)
-- Name: drive_day_2017_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q2_date_idx ON public.drive_day_2017_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4281 (class 1259 OID 36820)
-- Name: drive_day_2017_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q2_date_idx1 ON public.drive_day_2017_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4282 (class 1259 OID 36763)
-- Name: drive_day_2017_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q2_drive_id_date_idx ON public.drive_day_2017_q2 USING btree (drive_id, date);


--
-- TOC entry 4285 (class 1259 OID 36707)
-- Name: drive_day_2017_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q3_date_idx ON public.drive_day_2017_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4286 (class 1259 OID 36821)
-- Name: drive_day_2017_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q3_date_idx1 ON public.drive_day_2017_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4287 (class 1259 OID 36764)
-- Name: drive_day_2017_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q3_drive_id_date_idx ON public.drive_day_2017_q3 USING btree (drive_id, date);


--
-- TOC entry 4290 (class 1259 OID 36708)
-- Name: drive_day_2017_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q4_date_idx ON public.drive_day_2017_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4291 (class 1259 OID 36822)
-- Name: drive_day_2017_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q4_date_idx1 ON public.drive_day_2017_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4292 (class 1259 OID 36765)
-- Name: drive_day_2017_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2017_q4_drive_id_date_idx ON public.drive_day_2017_q4 USING btree (drive_id, date);


--
-- TOC entry 4295 (class 1259 OID 36709)
-- Name: drive_day_2018_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q1_date_idx ON public.drive_day_2018_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4296 (class 1259 OID 36823)
-- Name: drive_day_2018_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q1_date_idx1 ON public.drive_day_2018_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4297 (class 1259 OID 36766)
-- Name: drive_day_2018_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q1_drive_id_date_idx ON public.drive_day_2018_q1 USING btree (drive_id, date);


--
-- TOC entry 4300 (class 1259 OID 36710)
-- Name: drive_day_2018_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q2_date_idx ON public.drive_day_2018_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4301 (class 1259 OID 36824)
-- Name: drive_day_2018_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q2_date_idx1 ON public.drive_day_2018_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4302 (class 1259 OID 36767)
-- Name: drive_day_2018_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q2_drive_id_date_idx ON public.drive_day_2018_q2 USING btree (drive_id, date);


--
-- TOC entry 4305 (class 1259 OID 36711)
-- Name: drive_day_2018_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q3_date_idx ON public.drive_day_2018_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4306 (class 1259 OID 36825)
-- Name: drive_day_2018_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q3_date_idx1 ON public.drive_day_2018_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4307 (class 1259 OID 36768)
-- Name: drive_day_2018_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q3_drive_id_date_idx ON public.drive_day_2018_q3 USING btree (drive_id, date);


--
-- TOC entry 4310 (class 1259 OID 36712)
-- Name: drive_day_2018_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q4_date_idx ON public.drive_day_2018_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4311 (class 1259 OID 36826)
-- Name: drive_day_2018_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q4_date_idx1 ON public.drive_day_2018_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4312 (class 1259 OID 36769)
-- Name: drive_day_2018_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2018_q4_drive_id_date_idx ON public.drive_day_2018_q4 USING btree (drive_id, date);


--
-- TOC entry 4315 (class 1259 OID 36713)
-- Name: drive_day_2019_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q1_date_idx ON public.drive_day_2019_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4316 (class 1259 OID 36827)
-- Name: drive_day_2019_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q1_date_idx1 ON public.drive_day_2019_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4317 (class 1259 OID 36770)
-- Name: drive_day_2019_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q1_drive_id_date_idx ON public.drive_day_2019_q1 USING btree (drive_id, date);


--
-- TOC entry 4320 (class 1259 OID 36714)
-- Name: drive_day_2019_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q2_date_idx ON public.drive_day_2019_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4321 (class 1259 OID 36828)
-- Name: drive_day_2019_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q2_date_idx1 ON public.drive_day_2019_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4322 (class 1259 OID 36771)
-- Name: drive_day_2019_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q2_drive_id_date_idx ON public.drive_day_2019_q2 USING btree (drive_id, date);


--
-- TOC entry 4325 (class 1259 OID 36715)
-- Name: drive_day_2019_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q3_date_idx ON public.drive_day_2019_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4326 (class 1259 OID 36829)
-- Name: drive_day_2019_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q3_date_idx1 ON public.drive_day_2019_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4327 (class 1259 OID 36772)
-- Name: drive_day_2019_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q3_drive_id_date_idx ON public.drive_day_2019_q3 USING btree (drive_id, date);


--
-- TOC entry 4330 (class 1259 OID 36716)
-- Name: drive_day_2019_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q4_date_idx ON public.drive_day_2019_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4331 (class 1259 OID 36830)
-- Name: drive_day_2019_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q4_date_idx1 ON public.drive_day_2019_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4332 (class 1259 OID 36773)
-- Name: drive_day_2019_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2019_q4_drive_id_date_idx ON public.drive_day_2019_q4 USING btree (drive_id, date);


--
-- TOC entry 4335 (class 1259 OID 36717)
-- Name: drive_day_2020_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q1_date_idx ON public.drive_day_2020_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4336 (class 1259 OID 36831)
-- Name: drive_day_2020_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q1_date_idx1 ON public.drive_day_2020_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4337 (class 1259 OID 36774)
-- Name: drive_day_2020_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q1_drive_id_date_idx ON public.drive_day_2020_q1 USING btree (drive_id, date);


--
-- TOC entry 4340 (class 1259 OID 36718)
-- Name: drive_day_2020_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q2_date_idx ON public.drive_day_2020_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4341 (class 1259 OID 36832)
-- Name: drive_day_2020_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q2_date_idx1 ON public.drive_day_2020_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4342 (class 1259 OID 36775)
-- Name: drive_day_2020_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q2_drive_id_date_idx ON public.drive_day_2020_q2 USING btree (drive_id, date);


--
-- TOC entry 4345 (class 1259 OID 36719)
-- Name: drive_day_2020_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q3_date_idx ON public.drive_day_2020_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4346 (class 1259 OID 36833)
-- Name: drive_day_2020_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q3_date_idx1 ON public.drive_day_2020_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4347 (class 1259 OID 36776)
-- Name: drive_day_2020_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q3_drive_id_date_idx ON public.drive_day_2020_q3 USING btree (drive_id, date);


--
-- TOC entry 4350 (class 1259 OID 36720)
-- Name: drive_day_2020_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q4_date_idx ON public.drive_day_2020_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4351 (class 1259 OID 36834)
-- Name: drive_day_2020_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q4_date_idx1 ON public.drive_day_2020_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4352 (class 1259 OID 36777)
-- Name: drive_day_2020_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2020_q4_drive_id_date_idx ON public.drive_day_2020_q4 USING btree (drive_id, date);


--
-- TOC entry 4355 (class 1259 OID 36721)
-- Name: drive_day_2021_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q1_date_idx ON public.drive_day_2021_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4356 (class 1259 OID 36835)
-- Name: drive_day_2021_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q1_date_idx1 ON public.drive_day_2021_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4357 (class 1259 OID 36778)
-- Name: drive_day_2021_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q1_drive_id_date_idx ON public.drive_day_2021_q1 USING btree (drive_id, date);


--
-- TOC entry 4360 (class 1259 OID 36722)
-- Name: drive_day_2021_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q2_date_idx ON public.drive_day_2021_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4361 (class 1259 OID 36836)
-- Name: drive_day_2021_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q2_date_idx1 ON public.drive_day_2021_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4362 (class 1259 OID 36779)
-- Name: drive_day_2021_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q2_drive_id_date_idx ON public.drive_day_2021_q2 USING btree (drive_id, date);


--
-- TOC entry 4365 (class 1259 OID 36723)
-- Name: drive_day_2021_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q3_date_idx ON public.drive_day_2021_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4366 (class 1259 OID 36837)
-- Name: drive_day_2021_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q3_date_idx1 ON public.drive_day_2021_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4367 (class 1259 OID 36780)
-- Name: drive_day_2021_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q3_drive_id_date_idx ON public.drive_day_2021_q3 USING btree (drive_id, date);


--
-- TOC entry 4370 (class 1259 OID 36724)
-- Name: drive_day_2021_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q4_date_idx ON public.drive_day_2021_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4371 (class 1259 OID 36838)
-- Name: drive_day_2021_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q4_date_idx1 ON public.drive_day_2021_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4372 (class 1259 OID 36781)
-- Name: drive_day_2021_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2021_q4_drive_id_date_idx ON public.drive_day_2021_q4 USING btree (drive_id, date);


--
-- TOC entry 4375 (class 1259 OID 36725)
-- Name: drive_day_2022_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q1_date_idx ON public.drive_day_2022_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4376 (class 1259 OID 36839)
-- Name: drive_day_2022_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q1_date_idx1 ON public.drive_day_2022_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4377 (class 1259 OID 36782)
-- Name: drive_day_2022_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q1_drive_id_date_idx ON public.drive_day_2022_q1 USING btree (drive_id, date);


--
-- TOC entry 4380 (class 1259 OID 36726)
-- Name: drive_day_2022_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q2_date_idx ON public.drive_day_2022_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4381 (class 1259 OID 36840)
-- Name: drive_day_2022_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q2_date_idx1 ON public.drive_day_2022_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4382 (class 1259 OID 36783)
-- Name: drive_day_2022_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q2_drive_id_date_idx ON public.drive_day_2022_q2 USING btree (drive_id, date);


--
-- TOC entry 4385 (class 1259 OID 36727)
-- Name: drive_day_2022_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q3_date_idx ON public.drive_day_2022_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4386 (class 1259 OID 36841)
-- Name: drive_day_2022_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q3_date_idx1 ON public.drive_day_2022_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4387 (class 1259 OID 36784)
-- Name: drive_day_2022_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q3_drive_id_date_idx ON public.drive_day_2022_q3 USING btree (drive_id, date);


--
-- TOC entry 4390 (class 1259 OID 36728)
-- Name: drive_day_2022_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q4_date_idx ON public.drive_day_2022_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4391 (class 1259 OID 36842)
-- Name: drive_day_2022_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q4_date_idx1 ON public.drive_day_2022_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4392 (class 1259 OID 36785)
-- Name: drive_day_2022_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2022_q4_drive_id_date_idx ON public.drive_day_2022_q4 USING btree (drive_id, date);


--
-- TOC entry 4395 (class 1259 OID 36729)
-- Name: drive_day_2023_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q1_date_idx ON public.drive_day_2023_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4396 (class 1259 OID 36843)
-- Name: drive_day_2023_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q1_date_idx1 ON public.drive_day_2023_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4397 (class 1259 OID 36786)
-- Name: drive_day_2023_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q1_drive_id_date_idx ON public.drive_day_2023_q1 USING btree (drive_id, date);


--
-- TOC entry 4400 (class 1259 OID 36730)
-- Name: drive_day_2023_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q2_date_idx ON public.drive_day_2023_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4401 (class 1259 OID 36844)
-- Name: drive_day_2023_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q2_date_idx1 ON public.drive_day_2023_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4402 (class 1259 OID 36787)
-- Name: drive_day_2023_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q2_drive_id_date_idx ON public.drive_day_2023_q2 USING btree (drive_id, date);


--
-- TOC entry 4405 (class 1259 OID 36731)
-- Name: drive_day_2023_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q3_date_idx ON public.drive_day_2023_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4406 (class 1259 OID 36845)
-- Name: drive_day_2023_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q3_date_idx1 ON public.drive_day_2023_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4407 (class 1259 OID 36788)
-- Name: drive_day_2023_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q3_drive_id_date_idx ON public.drive_day_2023_q3 USING btree (drive_id, date);


--
-- TOC entry 4410 (class 1259 OID 36732)
-- Name: drive_day_2023_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q4_date_idx ON public.drive_day_2023_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4411 (class 1259 OID 36846)
-- Name: drive_day_2023_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q4_date_idx1 ON public.drive_day_2023_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4412 (class 1259 OID 36789)
-- Name: drive_day_2023_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2023_q4_drive_id_date_idx ON public.drive_day_2023_q4 USING btree (drive_id, date);


--
-- TOC entry 4415 (class 1259 OID 36733)
-- Name: drive_day_2024_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q1_date_idx ON public.drive_day_2024_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4416 (class 1259 OID 36847)
-- Name: drive_day_2024_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q1_date_idx1 ON public.drive_day_2024_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4417 (class 1259 OID 36790)
-- Name: drive_day_2024_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q1_drive_id_date_idx ON public.drive_day_2024_q1 USING btree (drive_id, date);


--
-- TOC entry 4420 (class 1259 OID 36734)
-- Name: drive_day_2024_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q2_date_idx ON public.drive_day_2024_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4421 (class 1259 OID 36848)
-- Name: drive_day_2024_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q2_date_idx1 ON public.drive_day_2024_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4422 (class 1259 OID 36791)
-- Name: drive_day_2024_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q2_drive_id_date_idx ON public.drive_day_2024_q2 USING btree (drive_id, date);


--
-- TOC entry 4425 (class 1259 OID 36735)
-- Name: drive_day_2024_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q3_date_idx ON public.drive_day_2024_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4426 (class 1259 OID 36849)
-- Name: drive_day_2024_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q3_date_idx1 ON public.drive_day_2024_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4427 (class 1259 OID 36792)
-- Name: drive_day_2024_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q3_drive_id_date_idx ON public.drive_day_2024_q3 USING btree (drive_id, date);


--
-- TOC entry 4430 (class 1259 OID 36736)
-- Name: drive_day_2024_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q4_date_idx ON public.drive_day_2024_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4431 (class 1259 OID 36850)
-- Name: drive_day_2024_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q4_date_idx1 ON public.drive_day_2024_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4432 (class 1259 OID 36793)
-- Name: drive_day_2024_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2024_q4_drive_id_date_idx ON public.drive_day_2024_q4 USING btree (drive_id, date);


--
-- TOC entry 4435 (class 1259 OID 36737)
-- Name: drive_day_2025_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q1_date_idx ON public.drive_day_2025_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4436 (class 1259 OID 36851)
-- Name: drive_day_2025_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q1_date_idx1 ON public.drive_day_2025_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4437 (class 1259 OID 36794)
-- Name: drive_day_2025_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q1_drive_id_date_idx ON public.drive_day_2025_q1 USING btree (drive_id, date);


--
-- TOC entry 4440 (class 1259 OID 36738)
-- Name: drive_day_2025_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q2_date_idx ON public.drive_day_2025_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4441 (class 1259 OID 36852)
-- Name: drive_day_2025_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q2_date_idx1 ON public.drive_day_2025_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4442 (class 1259 OID 36795)
-- Name: drive_day_2025_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q2_drive_id_date_idx ON public.drive_day_2025_q2 USING btree (drive_id, date);


--
-- TOC entry 4445 (class 1259 OID 36739)
-- Name: drive_day_2025_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q3_date_idx ON public.drive_day_2025_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4446 (class 1259 OID 36853)
-- Name: drive_day_2025_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q3_date_idx1 ON public.drive_day_2025_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4447 (class 1259 OID 36796)
-- Name: drive_day_2025_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q3_drive_id_date_idx ON public.drive_day_2025_q3 USING btree (drive_id, date);


--
-- TOC entry 4450 (class 1259 OID 36740)
-- Name: drive_day_2025_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q4_date_idx ON public.drive_day_2025_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4451 (class 1259 OID 36854)
-- Name: drive_day_2025_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q4_date_idx1 ON public.drive_day_2025_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4452 (class 1259 OID 36797)
-- Name: drive_day_2025_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2025_q4_drive_id_date_idx ON public.drive_day_2025_q4 USING btree (drive_id, date);


--
-- TOC entry 4455 (class 1259 OID 36741)
-- Name: drive_day_2026_q1_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q1_date_idx ON public.drive_day_2026_q1 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4456 (class 1259 OID 36855)
-- Name: drive_day_2026_q1_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q1_date_idx1 ON public.drive_day_2026_q1 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4457 (class 1259 OID 36798)
-- Name: drive_day_2026_q1_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q1_drive_id_date_idx ON public.drive_day_2026_q1 USING btree (drive_id, date);


--
-- TOC entry 4460 (class 1259 OID 36742)
-- Name: drive_day_2026_q2_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q2_date_idx ON public.drive_day_2026_q2 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4461 (class 1259 OID 36856)
-- Name: drive_day_2026_q2_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q2_date_idx1 ON public.drive_day_2026_q2 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4462 (class 1259 OID 36799)
-- Name: drive_day_2026_q2_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q2_drive_id_date_idx ON public.drive_day_2026_q2 USING btree (drive_id, date);


--
-- TOC entry 4465 (class 1259 OID 36743)
-- Name: drive_day_2026_q3_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q3_date_idx ON public.drive_day_2026_q3 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4466 (class 1259 OID 36857)
-- Name: drive_day_2026_q3_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q3_date_idx1 ON public.drive_day_2026_q3 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4467 (class 1259 OID 36800)
-- Name: drive_day_2026_q3_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q3_drive_id_date_idx ON public.drive_day_2026_q3 USING btree (drive_id, date);


--
-- TOC entry 4470 (class 1259 OID 36744)
-- Name: drive_day_2026_q4_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q4_date_idx ON public.drive_day_2026_q4 USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4471 (class 1259 OID 36858)
-- Name: drive_day_2026_q4_date_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q4_date_idx1 ON public.drive_day_2026_q4 USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4472 (class 1259 OID 36801)
-- Name: drive_day_2026_q4_drive_id_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_2026_q4_drive_id_date_idx ON public.drive_day_2026_q4 USING btree (drive_id, date);


--
-- TOC entry 4190 (class 1259 OID 36688)
-- Name: drive_day_date_brin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_date_brin ON ONLY public.drive_day USING brin (date) WITH (pages_per_range='128');


--
-- TOC entry 4191 (class 1259 OID 36745)
-- Name: drive_day_drive_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_drive_date_idx ON ONLY public.drive_day USING btree (drive_id, date);


--
-- TOC entry 4192 (class 1259 OID 36802)
-- Name: drive_day_failed_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_day_failed_date_idx ON ONLY public.drive_day USING btree (date) WHERE (failed IS TRUE);


--
-- TOC entry 4481 (class 1259 OID 36338)
-- Name: drive_lifecycle_failed_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_lifecycle_failed_idx ON public.drive_lifecycle USING btree (failed);


--
-- TOC entry 4482 (class 1259 OID 36336)
-- Name: drive_lifecycle_max_poh_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_lifecycle_max_poh_idx ON public.drive_lifecycle USING btree (max_poh);


--
-- TOC entry 4483 (class 1259 OID 36337)
-- Name: drive_lifecycle_model_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_lifecycle_model_name_idx ON public.drive_lifecycle USING btree (model_name);


--
-- TOC entry 4177 (class 1259 OID 37030)
-- Name: drive_model_capacity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_model_capacity_idx ON public.drive_model USING btree (nominal_capacity_bytes);


--
-- TOC entry 4178 (class 1259 OID 37031)
-- Name: drive_model_mfr_capacity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_model_mfr_capacity_idx ON public.drive_model USING btree (manufacturer_id, nominal_capacity_bytes);


--
-- TOC entry 4181 (class 1259 OID 33518)
-- Name: drive_model_model_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX drive_model_model_name_uq ON public.drive_model USING btree (model_name);


--
-- TOC entry 4188 (class 1259 OID 36292)
-- Name: drive_provider_model_serial_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX drive_provider_model_serial_uq ON public.drive USING btree (provider_id, model_id, serial_number);


--
-- TOC entry 4189 (class 1259 OID 33519)
-- Name: drive_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX drive_uq ON public.drive USING btree (provider_id, model_id, serial_number);


--
-- TOC entry 4479 (class 1259 OID 36323)
-- Name: model_lifetime_stats_drives_seen_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX model_lifetime_stats_drives_seen_idx ON public.model_lifetime_stats USING btree (drives_seen);


--
-- TOC entry 4480 (class 1259 OID 36322)
-- Name: model_lifetime_stats_failures_per_drive_year_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX model_lifetime_stats_failures_per_drive_year_idx ON public.model_lifetime_stats USING btree (failures_per_drive_year);


--
-- TOC entry 4478 (class 1259 OID 36305)
-- Name: model_quarter_stats_model_name_year_quarter_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX model_quarter_stats_model_name_year_quarter_idx ON public.model_quarter_stats USING btree (model_name, year, quarter);


--
-- TOC entry 4602 (class 2606 OID 36091)
-- Name: drive_day_load_log drive_day_load_log_batch_id_fkey; Type: FK CONSTRAINT; Schema: bb; Owner: -
--

ALTER TABLE ONLY bb.drive_day_load_log
    ADD CONSTRAINT drive_day_load_log_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.ingest_batch(batch_id) ON DELETE CASCADE;


--
-- TOC entry 4488 (class 2606 OID 29607)
-- Name: drive_day drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.drive_day
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4490 (class 2606 OID 29623)
-- Name: drive_day_2013_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4492 (class 2606 OID 29642)
-- Name: drive_day_2013_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4494 (class 2606 OID 29661)
-- Name: drive_day_2013_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4496 (class 2606 OID 29680)
-- Name: drive_day_2013_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4498 (class 2606 OID 29699)
-- Name: drive_day_2014_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4500 (class 2606 OID 29718)
-- Name: drive_day_2014_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4502 (class 2606 OID 29737)
-- Name: drive_day_2014_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4504 (class 2606 OID 29756)
-- Name: drive_day_2014_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4506 (class 2606 OID 29775)
-- Name: drive_day_2015_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4508 (class 2606 OID 29794)
-- Name: drive_day_2015_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4510 (class 2606 OID 29813)
-- Name: drive_day_2015_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4512 (class 2606 OID 29832)
-- Name: drive_day_2015_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4514 (class 2606 OID 29851)
-- Name: drive_day_2016_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4516 (class 2606 OID 29870)
-- Name: drive_day_2016_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4518 (class 2606 OID 29889)
-- Name: drive_day_2016_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4520 (class 2606 OID 29908)
-- Name: drive_day_2016_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4522 (class 2606 OID 29927)
-- Name: drive_day_2017_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4524 (class 2606 OID 29946)
-- Name: drive_day_2017_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4526 (class 2606 OID 29965)
-- Name: drive_day_2017_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4528 (class 2606 OID 29984)
-- Name: drive_day_2017_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4530 (class 2606 OID 30003)
-- Name: drive_day_2018_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4532 (class 2606 OID 30022)
-- Name: drive_day_2018_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4534 (class 2606 OID 30041)
-- Name: drive_day_2018_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4536 (class 2606 OID 30060)
-- Name: drive_day_2018_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4538 (class 2606 OID 30079)
-- Name: drive_day_2019_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4540 (class 2606 OID 30098)
-- Name: drive_day_2019_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4542 (class 2606 OID 30117)
-- Name: drive_day_2019_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4544 (class 2606 OID 30136)
-- Name: drive_day_2019_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4546 (class 2606 OID 30155)
-- Name: drive_day_2020_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4548 (class 2606 OID 30174)
-- Name: drive_day_2020_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4550 (class 2606 OID 30193)
-- Name: drive_day_2020_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4552 (class 2606 OID 30212)
-- Name: drive_day_2020_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4554 (class 2606 OID 30231)
-- Name: drive_day_2021_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4556 (class 2606 OID 30250)
-- Name: drive_day_2021_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4558 (class 2606 OID 30269)
-- Name: drive_day_2021_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4560 (class 2606 OID 30288)
-- Name: drive_day_2021_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4562 (class 2606 OID 30307)
-- Name: drive_day_2022_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4564 (class 2606 OID 30326)
-- Name: drive_day_2022_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4566 (class 2606 OID 30345)
-- Name: drive_day_2022_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4568 (class 2606 OID 30364)
-- Name: drive_day_2022_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4570 (class 2606 OID 30383)
-- Name: drive_day_2023_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4572 (class 2606 OID 30402)
-- Name: drive_day_2023_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4574 (class 2606 OID 30421)
-- Name: drive_day_2023_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4576 (class 2606 OID 30440)
-- Name: drive_day_2023_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4578 (class 2606 OID 30459)
-- Name: drive_day_2024_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4580 (class 2606 OID 30478)
-- Name: drive_day_2024_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4582 (class 2606 OID 30497)
-- Name: drive_day_2024_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4584 (class 2606 OID 30516)
-- Name: drive_day_2024_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4586 (class 2606 OID 30535)
-- Name: drive_day_2025_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4588 (class 2606 OID 30554)
-- Name: drive_day_2025_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4590 (class 2606 OID 30573)
-- Name: drive_day_2025_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4592 (class 2606 OID 30592)
-- Name: drive_day_2025_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4594 (class 2606 OID 30611)
-- Name: drive_day_2026_q1 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q1
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4596 (class 2606 OID 30630)
-- Name: drive_day_2026_q2 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q2
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4598 (class 2606 OID 30649)
-- Name: drive_day_2026_q3 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q3
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4600 (class 2606 OID 30668)
-- Name: drive_day_2026_q4 drive_day_drive_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q4
    ADD CONSTRAINT drive_day_drive_id_fkey FOREIGN KEY (drive_id) REFERENCES public.drive(drive_id);


--
-- TOC entry 4489 (class 2606 OID 29602)
-- Name: drive_day drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.drive_day
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4491 (class 2606 OID 29626)
-- Name: drive_day_2013_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4493 (class 2606 OID 29645)
-- Name: drive_day_2013_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4495 (class 2606 OID 29664)
-- Name: drive_day_2013_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4497 (class 2606 OID 29683)
-- Name: drive_day_2013_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2013_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4499 (class 2606 OID 29702)
-- Name: drive_day_2014_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4501 (class 2606 OID 29721)
-- Name: drive_day_2014_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4503 (class 2606 OID 29740)
-- Name: drive_day_2014_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4505 (class 2606 OID 29759)
-- Name: drive_day_2014_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2014_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4507 (class 2606 OID 29778)
-- Name: drive_day_2015_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4509 (class 2606 OID 29797)
-- Name: drive_day_2015_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4511 (class 2606 OID 29816)
-- Name: drive_day_2015_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4513 (class 2606 OID 29835)
-- Name: drive_day_2015_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2015_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4515 (class 2606 OID 29854)
-- Name: drive_day_2016_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4517 (class 2606 OID 29873)
-- Name: drive_day_2016_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4519 (class 2606 OID 29892)
-- Name: drive_day_2016_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4521 (class 2606 OID 29911)
-- Name: drive_day_2016_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2016_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4523 (class 2606 OID 29930)
-- Name: drive_day_2017_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4525 (class 2606 OID 29949)
-- Name: drive_day_2017_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4527 (class 2606 OID 29968)
-- Name: drive_day_2017_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4529 (class 2606 OID 29987)
-- Name: drive_day_2017_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2017_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4531 (class 2606 OID 30006)
-- Name: drive_day_2018_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4533 (class 2606 OID 30025)
-- Name: drive_day_2018_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4535 (class 2606 OID 30044)
-- Name: drive_day_2018_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4537 (class 2606 OID 30063)
-- Name: drive_day_2018_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2018_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4539 (class 2606 OID 30082)
-- Name: drive_day_2019_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4541 (class 2606 OID 30101)
-- Name: drive_day_2019_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4543 (class 2606 OID 30120)
-- Name: drive_day_2019_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4545 (class 2606 OID 30139)
-- Name: drive_day_2019_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2019_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4547 (class 2606 OID 30158)
-- Name: drive_day_2020_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4549 (class 2606 OID 30177)
-- Name: drive_day_2020_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4551 (class 2606 OID 30196)
-- Name: drive_day_2020_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4553 (class 2606 OID 30215)
-- Name: drive_day_2020_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2020_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4555 (class 2606 OID 30234)
-- Name: drive_day_2021_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4557 (class 2606 OID 30253)
-- Name: drive_day_2021_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4559 (class 2606 OID 30272)
-- Name: drive_day_2021_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4561 (class 2606 OID 30291)
-- Name: drive_day_2021_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2021_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4563 (class 2606 OID 30310)
-- Name: drive_day_2022_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4565 (class 2606 OID 30329)
-- Name: drive_day_2022_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4567 (class 2606 OID 30348)
-- Name: drive_day_2022_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4569 (class 2606 OID 30367)
-- Name: drive_day_2022_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2022_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4571 (class 2606 OID 30386)
-- Name: drive_day_2023_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4573 (class 2606 OID 30405)
-- Name: drive_day_2023_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4575 (class 2606 OID 30424)
-- Name: drive_day_2023_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4577 (class 2606 OID 30443)
-- Name: drive_day_2023_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2023_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4579 (class 2606 OID 30462)
-- Name: drive_day_2024_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4581 (class 2606 OID 30481)
-- Name: drive_day_2024_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4583 (class 2606 OID 30500)
-- Name: drive_day_2024_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4585 (class 2606 OID 30519)
-- Name: drive_day_2024_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2024_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4587 (class 2606 OID 30538)
-- Name: drive_day_2025_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4589 (class 2606 OID 30557)
-- Name: drive_day_2025_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4591 (class 2606 OID 30576)
-- Name: drive_day_2025_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4593 (class 2606 OID 30595)
-- Name: drive_day_2025_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2025_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4595 (class 2606 OID 30614)
-- Name: drive_day_2026_q1 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q1
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4597 (class 2606 OID 30633)
-- Name: drive_day_2026_q2 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q2
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4599 (class 2606 OID 30652)
-- Name: drive_day_2026_q3 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q3
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4601 (class 2606 OID 30671)
-- Name: drive_day_2026_q4 drive_day_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_day_2026_q4
    ADD CONSTRAINT drive_day_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4486 (class 2606 OID 29540)
-- Name: drive drive_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive
    ADD CONSTRAINT drive_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.drive_model(model_id);


--
-- TOC entry 4485 (class 2606 OID 29515)
-- Name: drive_model drive_model_manufacturer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive_model
    ADD CONSTRAINT drive_model_manufacturer_id_fkey FOREIGN KEY (manufacturer_id) REFERENCES public.manufacturer(manufacturer_id);


--
-- TOC entry 4487 (class 2606 OID 29535)
-- Name: drive drive_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drive
    ADD CONSTRAINT drive_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4484 (class 2606 OID 29484)
-- Name: ingest_batch ingest_batch_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingest_batch
    ADD CONSTRAINT ingest_batch_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.provider(provider_id);


--
-- TOC entry 4885 (class 0 OID 36324)
-- Dependencies: 352 4889
-- Name: drive_lifecycle; Type: MATERIALIZED VIEW DATA; Schema: public; Owner: -
--

REFRESH MATERIALIZED VIEW public.drive_lifecycle;


--
-- TOC entry 4886 (class 0 OID 36340)
-- Dependencies: 353 4885 4889
-- Name: model_hazard_5k; Type: MATERIALIZED VIEW DATA; Schema: public; Owner: -
--

REFRESH MATERIALIZED VIEW public.model_hazard_5k;


--
-- TOC entry 4884 (class 0 OID 36309)
-- Dependencies: 351 4889
-- Name: model_lifetime_stats; Type: MATERIALIZED VIEW DATA; Schema: public; Owner: -
--

REFRESH MATERIALIZED VIEW public.model_lifetime_stats;


--
-- TOC entry 4883 (class 0 OID 36293)
-- Dependencies: 350 4889
-- Name: model_quarter_stats; Type: MATERIALIZED VIEW DATA; Schema: public; Owner: -
--

REFRESH MATERIALIZED VIEW public.model_quarter_stats;


-- Completed on 2026-02-21 14:37:29 CST

--
-- PostgreSQL database dump complete
--

\unrestrict shCDSgnznPTlidmnO5rOAM3DVBB8ej3Po0IajnvrpRPqdRJbJLczK7rgRqMUdi7

