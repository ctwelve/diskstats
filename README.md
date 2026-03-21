# diskstats
Tooling to store and analyze disk reliability data, especially from Backblaze.

**WARNING:** This project is in active development and still alpha-quality.

## Project intent

`diskstats` ingests large SMART datasets (currently Backblaze), normalizes them into query-friendly relational tables, and provides a foundation for reliability analysis.

Today the repository focuses on:

- repeatable ingest and normalization pipelines
- stable table design for daily drive telemetry
- canonical model/manufacturer mapping to tame source data noise
- operational tooling for long-running jobs

## Architecture (high-level)

Pipeline shape:

1. Download/extract quarterly archives (`bin/bb_dl`, optionally `bin/bb_dl_legacy`)
2. Raw ingest into `bb.drive_stats_raw` (`bin/bb_load.py`)
3. Normalize into canonical tables (`bin/bb_norm` → `bb.load_drive_day_backfill`)
4. Query/analysis against normalized facts (`public.drive_day`) and dimensions (`public.drive`, `public.drive_model`, etc.)

Data domains:

- `bb.*`: source-specific raw/staging objects (Backblaze)
- `public.*`: provider-agnostic canonical dimensions/facts

## Requirements

- PostgreSQL with `psql` available in `PATH`
- Python 3 with `psycopg2` installed (required by `bin/bb_load.py`)
- `wget`, `zip`, `unzip`, and `flock` in `PATH`
- A host/environment that can run long jobs reliably (for example, utility VM + `screen`/`tmux`)
- Enough CPU and memory bandwidth for long normalization runs (multi-core server recommended)
- Sufficient local storage: plan for at least 500 GB free for full download/extract/load + database growth
- A `PSQL_DSN` value via environment variable or `.env` in project root

## Run location and generated state

Run commands from the repository root (`diskstats/`) **inside a persistent shell session** (for example `tmux`/`screen`). Both download/ingest and normalization are long-running jobs on full datasets. Scripts create/use these directories and files:

- `downloads/`: downloaded archives
- `expanded/`: extracted CSV payloads
- `logs/`: job logs (`dl_*.log`, `norm_*.log`, etc.)
- `state_*.lock`: lock files used to prevent overlapping runs

## Quickstart

Set `PSQL_DSN` to the target `diskstats` DB for ingest/normalization:

```bash
export PSQL_DSN="postgresql://user:pass@localhost:5432/diskstats"
```

or create `.env` in project root:

```bash
PSQL_DSN=postgresql://user:pass@localhost:5432/diskstats
```

Then run:

```bash
bin/db_setup "postgresql://user:pass@localhost:5432/postgres"
bin/db_preflight
bin/bb_dl_legacy # Optional if you want pre-2016 data
bin/bb_dl
bin/bb_norm
```

## Built-in queries

`diskstats` ships with a harmonized collection of analytics **materialized views** in `sql/builtin-queries.sql`, installed by `bin/db_setup`.

Added built-ins:

- `public.model_fleet_latest_stats`: most recent-day fleet size/failure snapshot by model
- `public.model_reliability_90d`: trailing 90-day model reliability summary
- `public.model_smart_signals_30d`: trailing 30-day SMART signal prevalence and failure co-occurrence
- `public.model_lifetime_leaderboard`: lifetime model leaderboard (min 10,000 drive-days)

Related existing analytics materialized views already in schema:

- `public.drive_day_growth`
- `public.drive_lifecycle`
- `public.model_hazard_5k`
- `public.model_lifetime_stats`
- `public.model_quarter_stats`

Refresh the full analytics collection after large ingest/normalization runs:

```bash
psql "$PSQL_DSN" -c "CALL public.refresh_analytics_materialized_views();"
```

Example usage:

```bash
psql "$PSQL_DSN" -c "SELECT * FROM public.model_reliability_90d ORDER BY annualized_failures_per_drive_year DESC LIMIT 20;"
```

## Script reference

### `bin/db_setup`

Creates/rebuilds schema, seed data, and quarterly partitions. Use an admin-capable DSN (commonly `.../postgres`) because this can `DROP DATABASE` and `CREATE DATABASE`.

Useful flags:

- `--no-model-seed`
- `--no-model-alias`

### `bin/db_preflight`

Checks local tooling, DB connectivity, expected schema objects, and partition coverage before long jobs.

### `bin/bb_dl_legacy` and `bin/bb_dl`

Download and ingest Backblaze quarterly datasets into `bb.drive_stats_raw`. Run from a persistent shell (`tmux`/`screen`) for full loads.

- `bb_dl_legacy`: older dataset ranges
- `bb_dl`: current quarterly dataset pages/archives

Both scripts are lock-protected and should not run in parallel with each other.

### `bin/bb_norm`

Calls `bb.load_drive_day_backfill(start_year, end_year, continue_on_error)` to normalize from raw ingest into `public.drive_day` and related canonical dimensions.

- Emits quarter-level progress notices (start/skip/done/error, rows, elapsed)
- Emits monthly chunk heartbeats within each quarter
- Intended for very long runs; use `tmux`/`screen`

## Operational guidance

Observed runtime guidance:

- Full raw ingest can take many hours (around 8 hours in one observed environment) and may process hundreds of millions of rows
- Full normalization can run for multiple days
- Normalization is typically CPU + memory-bandwidth bound

Recommended process:

1. Run `bin/db_preflight`
2. Start downloads/ingest in a persistent session (`tmux`/`screen`)
3. Start normalization in a persistent session (`tmux`/`screen`)
4. Monitor `logs/` and keep lock files intact

## Troubleshooting

### `ERROR: invalid transaction termination` during `bb_norm`

`bb.load_drive_day_backfill` performs internal `COMMIT`s. Ensure the procedure is called as a top-level statement from `psql` (not inside an explicit `BEGIN ... COMMIT` block, and not wrapped in a way that forces transaction-block semantics).

### Preflight fails on partition coverage

Run `db_setup` (or `public.ensure_core_partitions(start_year, end_year)`) to create missing quarterly partitions.

### Missing `PSQL_DSN`

Export `PSQL_DSN` or add it to `.env` in project root.

## SQL seed structure

- `seed-manufacturer.sql`: curated manufacturer reference rows
- `seed-drive-model-curated.sql`: curated `public.drive_model` rows
- `seed-model-alias.sql`: deterministic exact aliases (`raw model_name -> model_id`)

For SQL object layout and procedure inventory, see `sql/README.md`.
