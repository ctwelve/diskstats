# diskstats
Tooling to store and analyze disk reliability data, especially from BackBlaze

**WARNING:** This project is very much in active development! I'm nowhere near declaring this as even beta-quality; this is alpha-quality software at *best.*

I'm also not really much of a programmer; by trade I am a network engineer. If you see anything that's wildly out of spec, broken, etc., I'm happy to take feedback or PRs, but please keep in mind I don't do this sort of thing for a living! I am a rank amateur.

That said, this shouln't be too hard for the tech-savvy to use, even in its raw form. Let me know if this helps!

## Goals

Eventually, this will likely include a suite of views and such to help you pick out the "best" drives from the available data. That being a highly opinionated and fraught topic, for now this should just be the tooling necessary to process the data in some reasonable form. We'll get to the opinionated analysis later.

## Requirements

- PostgreSQL with `psql` available in `PATH`
- Python 3 with `psycopg2` installed (required by `bin/bb_load.py`)
- `wget`, `zip`, `unzip`, and `flock` available in `PATH`
- A host/environment that can run long jobs reliably (for example, utility VM + `screen`/`tmux`)
- Enough CPU and memory bandwidth for long normalization runs (multi-core server recommended)
- Sufficient local storage: plan for at least 500 GB free for full download/extract/load + database growth
- A `PSQL_DSN` value available via environment variable or `.env` file in project root


## Long-running scripts

The `bb_*` scripts can run for a long time. Run them from a stable session/environment (for example, `screen` or `tmux` on a utility VM) so interruptions in your local terminal do not kill active ingest/normalization jobs.
`bin/bb_dl` and `bin/bb_dl_legacy` also share a lock file and should be run one at a time.

Observed runtime guidance:

- Full raw ingest can take many hours (around 8 hours in one observed environment).
- Normalization (`bin/bb_norm`) can run for multiple days.
- In practice, normalization tends to be CPU and memory-bandwidth bound more than raw disk throughput.


## Run location

Run commands from your intended project root. For most users:

1. Navigate to an appropriate location via the command prompt
2. `git clone` this repository, then `cd diskstats`
3. go through the quickstart, below.

The toolchain will create folders to hold the downloaded archives, their expanded contents, logging, etc. Be warned, this is a big pile of data; the downloads alone will need ~250 GB, most likely.


## Quickstart flow

Set `PSQL_DSN` to the `diskstats` database for ingest/normalization:

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
bin/bb_dl_legacy ## Optional, if you care about data from 2013-2016
bin/bb_dl
bin/bb_norm
```

What this does:

1. `bin/db_setup`
Creates/rebuilds the `diskstats` database schema, seed data, and quarterly partitions. This step should use an admin-capable DSN (commonly `.../postgres`) because it performs `DROP DATABASE` and `CREATE DATABASE`.

2. `bin/db_preflight`
Runs readiness checks before long-running jobs: tooling, connectivity, schema objects, and partition coverage.

3. `bin/bb_dl_legacy` and `bin/bb_dl`
Downloads Backblaze quarterly ZIPs through the most recently published quarter (typically one quarter behind the calendar quarter) and ingests raw CSV data into `bb.drive_stats_raw`. Use `bin/bb_dl_legacy` to ingest legacy pre-2016 Backblaze archives.

4. `bin/bb_norm`
Runs normalization procedures that populate `public.drive_day` (and related canonical model mappings), making the dataset ready for querying and analysis.
During long runs, it now emits progress notices at quarter boundaries (start/skip/done/error, rows inserted, elapsed time, cumulative quarter progress) and monthly chunk heartbeats within each quarter.


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

Use a specific DSN for `psql` directly (overrides env/.env):

```bash
bin/db_setup "postgresql://user:pass@localhost:5432/postgres"
```

Run the preflight check before `bb_dl`/`bb_norm`:

```bash
bin/db_preflight
```

Reset/rebuild quickly (wraps `db_setup`):

```bash
bin/db_reset
```

## SQL seed structure

- `seed-manufacturer.sql`: curated manufacturer reference rows.
- `seed-drive-model-curated.sql`: curated `public.drive_model` fact rows.
- `seed-model-alias.sql`: deterministic exact aliases (`raw model_name -> model_id`).
