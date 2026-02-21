# diskstats
Tooling to store and analyze disk reliability data, especially from BackBlaze

## Database setup

Bootstrap schema (and optional model seeds):

```bash
bin/db_setup
```

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
- `/Users/ctwelve/Developer/diskstats/sql/seed-model-alias.sql`: deterministic exact aliases (`raw model_name -> model_id`) for Backblaze.
- `/Users/ctwelve/Developer/diskstats/sql/drive_model_curated.sql`: pg_dump-style source artifact used to produce curated seed data.
