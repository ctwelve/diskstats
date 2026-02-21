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

Use a specific admin DSN for `psql` (defaults to `postgresql:///postgres`):

```bash
bin/db_setup "postgresql://user:pass@localhost:5432/postgres"
```
