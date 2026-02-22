-- Patch: normalization procedure fixes
-- Apply with: psql "$PSQL_DSN" -v ON_ERROR_STOP=1 -f sql/patch-normalization-procs.sql

CREATE OR REPLACE PROCEDURE bb.load_drive_day_backfill(IN p_start_year integer DEFAULT 2013, IN p_end_year integer DEFAULT 2025, IN p_continue_on_error boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_provider_id smallint;
  v_batch_id bigint;
  v_quarters_total integer;
  v_quarters_done integer;
  v_quarters_error integer;

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

  IF txid_current_if_assigned() IS NOT NULL THEN
    RAISE EXCEPTION
      'bb.load_drive_day_backfill must be called with autocommit ON (not inside BEGIN/COMMIT).';
  END IF;

  SELECT provider_id INTO v_provider_id
  FROM public.provider
  WHERE name='backblaze';

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'Provider backblaze not found in public.provider';
  END IF;

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
    UPDATE bb.drive_day_load_log
    SET status = 'interrupted',
        finished_at = clock_timestamp(),
        error = COALESCE(error, 'Resumed batch; previous attempt ended unexpectedly')
    WHERE batch_id = v_batch_id
      AND status = 'running';

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

  v_quarters_total := ((p_end_year - p_start_year) + 1) * 4;
  RAISE NOTICE '[bb_norm] batch_id=% years=%..% total_quarters=% continue_on_error=%',
    v_batch_id, p_start_year, p_end_year, v_quarters_total, p_continue_on_error;

  FOR y IN p_start_year..p_end_year LOOP
    FOR q IN 1..4 LOOP
      start_date := make_date(y, (q*3)-2, 1);
      end_date := (start_date + interval '3 months')::date;

      IF EXISTS (
        SELECT 1
        FROM bb.drive_day_load_log
        WHERE batch_id = v_batch_id
          AND year = y
          AND quarter = q
          AND status = 'done'
      ) THEN
        RAISE NOTICE '[bb_norm] skip % Q% (% to %) already done',
          y, q, start_date, end_date;
        CONTINUE;
      END IF;

      t0 := clock_timestamp();
      RAISE NOTICE '[bb_norm] start % Q% (% to %)',
        y, q, start_date, end_date;

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
        SELECT
          count(*) FILTER (WHERE status = 'done'),
          count(*) FILTER (WHERE status = 'error')
        INTO v_quarters_done, v_quarters_error
        FROM bb.drive_day_load_log
        WHERE batch_id = v_batch_id;

        RAISE NOTICE '[bb_norm] done % Q% rows=% elapsed=% progress=%/% errors=%',
          y, q, v_rows, (t1 - t0), v_quarters_done, v_quarters_total, v_quarters_error;
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
        SELECT
          count(*) FILTER (WHERE status = 'done'),
          count(*) FILTER (WHERE status = 'error')
        INTO v_quarters_done, v_quarters_error
        FROM bb.drive_day_load_log
        WHERE batch_id = v_batch_id;

        RAISE NOTICE '[bb_norm] error % Q% elapsed=% progress=%/% errors=% detail=%',
          y, q, (t1 - t0), v_quarters_done, v_quarters_total, v_quarters_error, v_err;

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

  SELECT
    count(*) FILTER (WHERE status = 'done'),
    count(*) FILTER (WHERE status = 'error')
  INTO v_quarters_done, v_quarters_error
  FROM bb.drive_day_load_log
  WHERE batch_id = v_batch_id;

  RAISE NOTICE '[bb_norm] finished batch_id=% done_quarters=%/% error_quarters=%',
    v_batch_id, v_quarters_done, v_quarters_total, v_quarters_error;

  COMMIT;
END$$;

CREATE OR REPLACE PROCEDURE bb.load_drive_day_range(IN p_from date, IN p_to date, OUT rows_inserted bigint)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_chunk_from date;
  v_chunk_to date;
  v_rows_chunk bigint;
  v_t0 timestamptz;
  v_t1 timestamptz;
BEGIN
  SET LOCAL synchronous_commit = off;
  SET LOCAL work_mem = '256MB';
  rows_inserted := 0;

  -- Ensure canonical dimensions exist before fact insert.
  CALL bb.ensure_backblaze_drive_models_for_range(p_from, p_to);
  CALL bb.ensure_backblaze_drives_for_range(p_from, p_to);

  v_chunk_from := p_from;
  WHILE v_chunk_from < p_to LOOP
    v_chunk_to := LEAST((v_chunk_from + interval '1 month')::date, p_to);
    v_t0 := clock_timestamp();

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
        WHERE ma.raw_model_name = btrim(r.model)
          AND ma.is_active

        UNION ALL

        SELECT m2.model_id, 2 AS priority
        FROM public.drive_model m2
        WHERE m2.model_name = btrim(r.model)
      ) AS candidate
      ORDER BY candidate.priority, candidate.model_id
      LIMIT 1
    ) model_resolve ON true
    JOIN public.drive d
      ON d.provider_id = p.provider_id
     AND d.model_id = model_resolve.model_id
     AND d.serial_number = btrim(r.serial_number)
    WHERE r.date >= v_chunk_from
      AND r.date <  v_chunk_to
    ON CONFLICT (provider_id, drive_id, date) DO NOTHING;

    GET DIAGNOSTICS v_rows_chunk = ROW_COUNT;
    rows_inserted := rows_inserted + v_rows_chunk;
    v_t1 := clock_timestamp();

    RAISE NOTICE '[bb_norm] chunk % to % rows=% cumulative_rows=% elapsed=%',
      v_chunk_from, v_chunk_to, v_rows_chunk, rows_inserted, (v_t1 - v_t0);

    v_chunk_from := v_chunk_to;
  END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE bb.ensure_backblaze_drive_models_for_range(IN p_from date, IN p_to date)
    LANGUAGE plpgsql
    AS $$
BEGIN
  WITH raw_models AS (
    SELECT
      btrim(r.model) AS raw_model_name,
      max(r.capacity_bytes) AS max_capacity_bytes
    FROM bb.drive_stats_raw r
    WHERE r.date >= p_from
      AND r.date < p_to
      AND r.model IS NOT NULL
      AND btrim(r.model) <> ''
    GROUP BY btrim(r.model)
  )
  INSERT INTO public.drive_model (
    model_name,
    normalized_name,
    manufacturer_id,
    nominal_capacity_bytes,
    media_type
  )
  SELECT
    rm.raw_model_name,
    rm.raw_model_name,
    bb.infer_manufacturer_id_from_model_name(rm.raw_model_name),
    rm.max_capacity_bytes,
    bb.infer_media_type_from_model_name(rm.raw_model_name)
  FROM raw_models rm
  LEFT JOIN public.drive_model dm ON dm.model_name = rm.raw_model_name
  WHERE dm.model_id IS NULL;

  INSERT INTO public.model_alias (raw_model_name, model_id, match_method, notes)
  SELECT
    rm.raw_model_name,
    dm.model_id,
    'auto_raw',
    'Auto-created during load from raw model_name'
  FROM (
    SELECT DISTINCT btrim(r.model) AS raw_model_name
    FROM bb.drive_stats_raw r
    WHERE r.date >= p_from
      AND r.date < p_to
      AND r.model IS NOT NULL
      AND btrim(r.model) <> ''
  ) rm
  JOIN public.drive_model dm ON dm.model_name = rm.raw_model_name
  ON CONFLICT (raw_model_name) DO NOTHING;
END $$;

CREATE OR REPLACE PROCEDURE bb.ensure_backblaze_models_for_range(IN p_from date, IN p_to date)
    LANGUAGE plpgsql
    AS $$
BEGIN
  CALL bb.ensure_backblaze_drive_models_for_range(p_from, p_to);
END $$;

CREATE OR REPLACE PROCEDURE bb.ensure_backblaze_drives_for_range(IN p_from date, IN p_to date)
    LANGUAGE plpgsql
    AS $$
BEGIN
  WITH p AS (
    SELECT provider_id
    FROM public.provider
    WHERE name = 'backblaze'
  ),
  raw_drives AS (
    SELECT
      p.provider_id,
      btrim(r.serial_number) AS serial_number,
      btrim(r.model) AS raw_model_name,
      min(r.date) AS first_seen,
      max(r.date) AS last_seen
    FROM bb.drive_stats_raw r
    JOIN p ON true
    WHERE r.date >= p_from
      AND r.date < p_to
      AND r.serial_number IS NOT NULL
      AND btrim(r.serial_number) <> ''
      AND r.model IS NOT NULL
      AND btrim(r.model) <> ''
    GROUP BY p.provider_id, btrim(r.serial_number), btrim(r.model)
  )
  INSERT INTO public.drive (
    provider_id,
    model_id,
    serial_number,
    first_seen,
    last_seen
  )
  SELECT
    rd.provider_id,
    model_resolve.model_id,
    rd.serial_number,
    rd.first_seen,
    rd.last_seen
  FROM raw_drives rd
  JOIN LATERAL (
    SELECT candidate.model_id
    FROM (
      SELECT ma.model_id, 1 AS priority
      FROM public.model_alias ma
      WHERE ma.raw_model_name = rd.raw_model_name
        AND ma.is_active
      UNION ALL
      SELECT dm.model_id, 2 AS priority
      FROM public.drive_model dm
      WHERE dm.model_name = rd.raw_model_name
    ) candidate
    ORDER BY candidate.priority, candidate.model_id
    LIMIT 1
  ) model_resolve ON true
  ON CONFLICT (provider_id, model_id, serial_number) DO UPDATE
    SET first_seen = CASE
          WHEN public.drive.first_seen IS NULL THEN EXCLUDED.first_seen
          WHEN EXCLUDED.first_seen IS NULL THEN public.drive.first_seen
          ELSE LEAST(public.drive.first_seen, EXCLUDED.first_seen)
        END,
        last_seen = CASE
          WHEN public.drive.last_seen IS NULL THEN EXCLUDED.last_seen
          WHEN EXCLUDED.last_seen IS NULL THEN public.drive.last_seen
          ELSE GREATEST(public.drive.last_seen, EXCLUDED.last_seen)
        END;
END $$;

COMMENT ON PROCEDURE bb.load_drive_day_range(date, date) IS
  'Loads one date range from raw rows into public.drive_day; first ensures drive_model/model_alias and drive dimensions, then inserts normalized facts in monthly chunks with progress notices.';
COMMENT ON PROCEDURE bb.ensure_backblaze_drive_models_for_range(date, date) IS
  'Infers missing canonical models and exact aliases from raw Backblaze model strings for a date window.';
COMMENT ON PROCEDURE bb.ensure_backblaze_models_for_range(date, date) IS
  'Compatibility wrapper that delegates to bb.ensure_backblaze_drive_models_for_range.';
COMMENT ON PROCEDURE bb.ensure_backblaze_drives_for_range(date, date) IS
  'Infers missing provider/model/serial drive identities for a date window and updates first_seen/last_seen.';
