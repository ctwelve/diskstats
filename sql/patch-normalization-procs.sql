-- Patch: normalization procedure fixes
-- Apply with: psql "$PSQL_DSN" -v ON_ERROR_STOP=1 -f sql/patch-normalization-procs.sql

CREATE OR REPLACE PROCEDURE bb.load_drive_day_range(IN p_from date, IN p_to date, OUT rows_inserted bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  SET LOCAL synchronous_commit = off;
  SET LOCAL work_mem = '256MB';

  -- Ensure canonical dimensions exist before fact insert.
  CALL bb.ensure_backblaze_drive_models_for_range(p_from, p_to);
  CALL bb.ensure_backblaze_drives_for_range(p_from, p_to);

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
  WHERE r.date >= p_from
    AND r.date <  p_to
  ON CONFLICT (provider_id, drive_id, date) DO NOTHING;

  GET DIAGNOSTICS rows_inserted = ROW_COUNT;
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
  'Loads one date range from raw rows into public.drive_day; first ensures drive_model/model_alias and drive dimensions, then inserts normalized facts.';
COMMENT ON PROCEDURE bb.ensure_backblaze_drive_models_for_range(date, date) IS
  'Infers missing canonical models and exact aliases from raw Backblaze model strings for a date window.';
COMMENT ON PROCEDURE bb.ensure_backblaze_models_for_range(date, date) IS
  'Compatibility wrapper that delegates to bb.ensure_backblaze_drive_models_for_range.';
COMMENT ON PROCEDURE bb.ensure_backblaze_drives_for_range(date, date) IS
  'Infers missing provider/model/serial drive identities for a date window and updates first_seen/last_seen.';
