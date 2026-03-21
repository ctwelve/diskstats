# SQL layout and conventions

## File map

- `schema.sql`: canonical bootstrap script for the database (schemas, tables, indexes, procedures, comments, partitions)
- `seed-manufacturer.sql`: curated manufacturer rows for `public.manufacturer`
- `seed-drive-model-curated.sql`: curated canonical models for `public.drive_model`
- `seed-model-alias.sql`: exact deterministic alias mapping (`raw model_name -> model_id`)
- `patch-normalization-procs.sql`: focused patch script for normalization procedures during iterative development/fixes
- `builtin-queries.sql`: built-in analytics materialized views for common high-volume workflows

## Object layering

- `bb.*` objects are source-specific ingest/staging for Backblaze
- `public.*` objects are canonical/provider-agnostic dimensions and facts

This separation keeps raw fidelity while allowing stable analytics schemas.

## Core normalization flow

1. Raw records land in `bb.drive_stats_raw`
2. Model aliases/dimensions are ensured (`bb.ensure_backblaze_drive_models_for_range`)
3. Drive identities are ensured (`bb.ensure_backblaze_drives_for_range`)
4. Daily facts are inserted into `public.drive_day` (`bb.load_drive_day_range`)
5. Quarter orchestration, logging, and resume semantics are handled by `bb.load_drive_day_backfill`

## Why `model_alias` exists

- `drive_model` stores canonical model facts (one row per curated model)
- `model_alias` absorbs raw string variation from source data
- many-to-one mapping enables:
  - auditability
  - easier corrections
  - no rewrite of raw history when aliases improve

## Utility procedures

- `CALL bb.ensure_backblaze_drive_models_for_range(<from>, <to>);`
  - adds missing canonical models and aliases inferred from raw rows
- `CALL bb.ensure_backblaze_models_for_range(<from>, <to>);`
  - compatibility alias of the above
- `CALL bb.ensure_backblaze_drives_for_range(<from>, <to>);`
  - upserts canonical drive identities (provider/model/serial + first/last seen)
- `CALL public.ensure_core_partitions(<start_year>, <end_year>);`
  - creates quarterly partitions for `bb.drive_stats_raw` and `public.drive_day`

## Seed order (preferred)

1. `seed-manufacturer.sql`
2. `seed-drive-model-curated.sql`
3. `seed-model-alias.sql`

## Notes for contributors

- Keep schema comments current when adding/modifying SQL objects; comments are part of the operational docs.
- Prefer additive migration/patch scripts (like `patch-normalization-procs.sql`) while iterating, then fold into `schema.sql` when stabilizing.
- If a procedure performs transaction control (`COMMIT`/`ROLLBACK`), document expected invocation semantics in both SQL comments and script-level docs.

## Built-in analytics materialized views

- `builtin-queries.sql`: curated analytics materialized views and refresh helper (`public.refresh_analytics_materialized_views()`) for the public-schema query collection

Installed by `bin/db_setup` after schema + seed scripts (skip with `--no-builtin-queries`).
