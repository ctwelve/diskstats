# SQL Layout

- `schema.sql`: canonical schema/bootstrap script (creates DB, switches context, defines all objects).
- `seed-manufacturer.sql`: curated manufacturer rows.
- `seed-drive-model-curated.sql`: curated `public.drive_model` seed data.
- `seed-model-alias.sql`: deterministic exact Backblaze aliases (`raw model_name -> model_id`).

## Why `model_alias` Exists

- `drive_model` is the canonical model catalog (one row per curated model).
- `model_alias` maps raw strings to canonical `drive_model.model_id`.
- This separates source variability from canonical facts:
  - many raw forms can map to one curated model
  - mapping is auditable and easy to correct without rewriting raw data

## Optional utility procedures

- `CALL bb.ensure_backblaze_drive_models_for_range(<from>, <to>);`
  - Adds missing `drive_model` rows and exact aliases from raw rows in a date window using heuristic manufacturer/media inference.
- `CALL bb.ensure_backblaze_models_for_range(<from>, <to>);`
  - Compatibility alias for `bb.ensure_backblaze_drive_models_for_range(...)`.
- `CALL bb.ensure_backblaze_drives_for_range(<from>, <to>);`
  - Adds/updates `public.drive` rows (provider + model + serial identity, first/last seen) from raw ingest in a date window.
- `CALL public.ensure_core_partitions(<start_year>, <end_year>);`
  - Creates quarterly partitions for both partitioned fact tables (`bb.drive_stats_raw`, `public.drive_day`).

## Preferred seed order

1. `seed-manufacturer.sql`
2. `seed-drive-model-curated.sql`
3. `seed-model-alias.sql`
