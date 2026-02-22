# diskstats
Tooling to store and analyze disk reliability data, especially from BackBlaze

## Requirements

- PostgreSQL with `psql` available in `PATH`
- Python 3 with `psycopg2` installed (required by `bin/bb_load.py`)
- A host/environment that can run long jobs reliably (for example, utility VM + `screen`/`tmux`)
- Sufficient local storage: plan for at least 500 GB free for full download/extract/load + database growth

## Long-running scripts

The `bb_*` scripts can run for a long time. Run them from a stable session/environment (for example, `screen` or `tmux` on a utility VM) so interruptions in your local terminal do not kill active ingest/normalization jobs.

## Run location

Run commands from your intended project root. For most users:

1. Navigate to an appropriate location via the command prompt
2. `git clone` this repository, then `cd diskstats`
3. go through the quickstart, below.

The toolchain will create folders to hold the downloaded archives, their expanded contents, logging, etc. Be warned, this is a big pile of data; the downloads alone will need ~250 GB, most likely.

## Quickstart flow

Set a connection string to PostgreSQL in `PSQL_DSN`, then run:

```bash
bin/db_setup
bin/bb_dl_legacy ## Optional, if you care about data from 2013-2016
bin/bb_dl
bin/bb_norm
```

What this does:

1. `bin/db_setup`
Creates the database schema, seed data, and quarterly partitions.

2. `bin/bb_dl_legacy` and `bin/bb_dl`
Downloads the complete current Backblaze quarterly dataset and ingests raw CSV data into `bb.drive_stats_raw`. Use `bin/bb_dl_legacy` to ingest legacy pre-2016 Backblaze archives.

3. `bin/bb_norm`
Runs normalization procedures that populate `public.drive_day` (and related canonical model mappings), making the dataset ready for querying and analysis.


## Database setup

Bootstrap schema (and optional model seeds):

```bash
bin/db_setup
```

By default this bootstrap also pre-creates quarterly partitions (2013..2026) for:

- `bb.drive_stats_raw`
- `public.drive_day`

Skip optional model seed data:

```bash
bin/db_setup --no-model-seed
```

Skip optional exact model alias seed data:

```bash
bin/db_setup --no-model-alias
```

Use a specific admin DSN for `psql` (defaults to `postgresql:///postgres`):

```bash
bin/db_setup "postgresql://user:pass@localhost:5432/postgres"
```

Reset/rebuild quickly (wraps `db_setup`):

```bash
bin/db_reset
```

## SQL seed structure

- `/Users/ctwelve/Developer/diskstats/sql/seed-manufacturer.sql`: curated manufacturer reference rows.
- `/Users/ctwelve/Developer/diskstats/sql/seed-drive-model-curated.sql`: curated `public.drive_model` fact rows.
- `/Users/ctwelve/Developer/diskstats/sql/seed-model-alias.sql`: deterministic exact aliases (`raw model_name -> model_id`).
