# Database Migrations (Postgres + Vapor/Fluent)

This project uses **Fluent migrations** to manage the Postgres schema.
In production and on the Raspberry Pi, run migrations using the Swift executable (no Vapor CLI needed).

---

## Quick Start (Raspberry Pi / Production)

From the project root (where `Package.swift` lives):

```bash
cd ~/pickdriver-vapor-api
git pull
swift build
swift run PickdriverVaporApi migrate
pm2 restart vapor-api
```

If there are no pending migrations, `migrate` finishes without changes.

---

## Verify Migration State (Postgres)

Connect to Postgres:

```bash
psql "postgresql://<USER>:<PASS>@<HOST>:5432/<DBNAME>"
```

Check Fluent migration history table (Fluent uses `_fluent_migrations`):

```sql
SELECT name, batch, created_at
FROM public._fluent_migrations
ORDER BY created_at;
```

List tables (useful for sanity checks):

```sql
SELECT tablename
FROM pg_tables
WHERE schemaname='public'
ORDER BY tablename;
```

---

## Common Workflow

### 1) Add a new migration
- Create a new `AsyncMigration` in the appropriate file (e.g. `AuthMigrations.swift`, `NotificationMigrations.swift`, etc.).
- Register it in `configure.swift` (order matters).

### 2) Deploy + apply
```bash
cd ~/pickdriver-vapor-api
git pull
swift build
swift run PickdriverVaporApi migrate
pm2 restart vapor-api
```

---

## Rules / Best Practices

- **Never modify** a migration that has already run on production.
- For schema changes, always create a **new migration** (ALTER TABLE / CREATE INDEX / etc.).
- Avoid destructive operations in production unless you are sure (dropping columns/tables).
- Always keep a backup before major changes.

---

## Special Case: Existing DB without migration history (“Stamping”)

Sometimes the database already contains tables (created manually or restored from a dump),
but `_fluent_migrations` does not include the full history. In that case, Fluent will try to
create everything from scratch and fail with errors like:

- `relation "seasons" already exists`

### Goal
Populate `_fluent_migrations` with the migrations that are already reflected in the DB schema,
so Fluent will only run the truly new migrations.

### Safety: Backup first
```bash
pg_dump -Fc -h <HOST> -U <USER> -d <DBNAME> > backup_before_stamp.dump
```

### Check current migration history
```sql
SELECT name, batch, created_at
FROM public._fluent_migrations
ORDER BY created_at;
```

### Stamp base migrations (example template)
This inserts “already-applied” entries only if they don’t exist.

> Note: This template uses `pgcrypto` to generate UUIDs. If your `_fluent_migrations.id`
> requires UUID and has no default, this is the cleanest approach.

```bash
psql "postgresql://<USER>:<PASS>@<HOST>:5432/<DBNAME>" <<SQL
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO public._fluent_migrations (id, name, batch, created_at, updated_at)
SELECT gen_random_uuid(), x.name, 1, now(), now()
FROM (VALUES
  ('PickdriverVaporApi.CreateSeasons'),
  ('PickdriverVaporApi.CreateUsers'),
  ('PickdriverVaporApi.CreateF1Teams'),
  ('PickdriverVaporApi.CreateDrivers'),
  ('PickdriverVaporApi.CreateRaces'),
  ('PickdriverVaporApi.CreateLeagues'),
  ('PickdriverVaporApi.CreateLeagueMembers'),
  ('PickdriverVaporApi.CreateLeagueTeams'),
  ('PickdriverVaporApi.CreateTeamMembers'),
  ('PickdriverVaporApi.CreateRaceDrafts'),
  ('PickdriverVaporApi.CreatePlayerPicks'),
  ('PickdriverVaporApi.CreatePlayerBans'),
  ('PickdriverVaporApi.CreateRaceResults'),
  ('PickdriverVaporApi.CreateMaintenanceStats')
) AS x(name)
WHERE NOT EXISTS (
  SELECT 1 FROM public._fluent_migrations m WHERE m.name = x.name
);

COMMIT;
SQL
```

After stamping, run migrations normally:

```bash
cd ~/pickdriver-vapor-api
swift run PickdriverVaporApi migrate
```

### Validate after stamping
```sql
SELECT name, batch, created_at
FROM public._fluent_migrations
ORDER BY created_at;
```

---

## Post-migration sanity checks (examples)

### Users table columns
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema='public' AND table_name='users'
ORDER BY ordinal_position;
```

### Check notification tables exist
```sql
SELECT tablename
FROM pg_tables
WHERE schemaname='public'
  AND tablename IN ('push_tokens', 'push_notifications', 'player_autopicks')
ORDER BY tablename;
```

---

## Troubleshooting

### `error: no executable product named 'App'`
Use the real executable name. In this project it is:

```bash
swift run PickdriverVaporApi migrate
```

### `relation already exists`
Your DB schema exists but `_fluent_migrations` is missing entries.
Use the “Stamping” section above.

### `fluent_migrations does not exist`
Fluent uses `_fluent_migrations` (with underscore) in this setup:

```sql
SELECT * FROM public._fluent_migrations;
```

