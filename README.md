# diskstats
Tooling to store and analyze disk reliability data, especially from BackBlaze

## Backblaze workflow

1. Download + ingest quarterly datasets:

```bash
bin/bb_dl
```

2. Optional legacy ingest (pre-2016):

```bash
bin/bb_dl_legacy
```

3. Normalize raw data into `public.drive_day`:

```bash
bin/bb_norm
```

## Long-running scripts

The `bb_*` scripts can run for a long time. Run them from a stable session/environment (for example, `screen` or `tmux` on a utility VM) so interruptions in your local terminal do not kill active ingest/normalization jobs.

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
- `/Users/ctwelve/Developer/diskstats/sql/drive_model_curated.sql`: pg_dump-style source artifact used to produce curated seed data.
