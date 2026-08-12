# Database Migrations (Postgres + Vapor/Fluent)

This project uses **Fluent migrations** to manage the Postgres schema.
In production and on the Raspberry Pi, run migrations using the Swift executable (no Vapor CLI needed).

---

## Quick Start (Raspberry Pi / Production)

From the project root (where `Package.swift` lives):

```bash
cd ~/pickdriver-vapor-api
swift build -c release
.build/release/PickdriverVaporApi migrate --yes
pm2 restart vapor-api --update-env
```

The Raspberry Pi deployment uses Swiftly. Its non-interactive SSH sessions may not put Swift on `PATH`; in that environment invoke the installed executable explicitly, for example:

```bash
"$HOME/.local/share/swiftly/bin/swift" build -c release
```

Apply migrations before restarting the API. This keeps the existing binary serving while an additive migration is prepared, and ensures the new binary never starts against an older schema. Verify the local process afterwards on `http://127.0.0.1:3000/api/health/ready`.

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
swift build -c release
.build/release/PickdriverVaporApi migrate --yes
pm2 restart vapor-api --update-env
```

---

## Account Deletion Migration

The account-deletion feature introduces:
- migration: `AddDeletedAtToUsers`
- schema changes:
  - `users.deleted_at` (`timestamp without time zone`, nullable)
  - index `idx_users_deleted_at`

Deployment requirement:
- run migrations before (or as part of) API rollout so `DELETE /api/auth/account` works correctly.

Verification query:
```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema='public' AND table_name='users' AND column_name='deleted_at';
```

```sql
SELECT indexname
FROM pg_indexes
WHERE schemaname='public' AND tablename='users' AND indexname='idx_users_deleted_at';
```

---

## Playoffs Migrations

The initial playoffs feature introduces migration `CreateLeaguePlayoffs`:

- `league_playoffs`: one persisted playoff bracket per league, including the regular-race boundary, the complete locked set of playoff race IDs, first playoff race, selection deadline, frozen standings order, group size, and finalized first pick order.
- `league_playoff_pick_selections`: one position-selection record per seeded player, with unique ranks and chosen positions.

The opt-in configuration introduces migration `AddLeaguePlayoffConfiguration`:

- `leagues.playoffs_enabled`: defaults to `false`; a persisted, existing playoff bracket is backfilled to `true` to preserve its authoritative state.
- `leagues.playoff_schedule_anchor_round`: the first effective draft round. Existing leagues are backfilled from `initial_race_round`; new leagues set it transactionally when `start-draft` succeeds.
- `leagues.playoff_schedule_anchor_at`: UTC audit timestamp for anchors created after this migration.

Deployment requirement:

- Apply `AddLeaguePlayoffConfiguration` before deploying the API version that exposes `playoffs_enabled` and the internal configuration endpoint.
- Existing active leagues remain compatible: playoffs are disabled unless they already have a persisted bracket. Enable a league only via `PATCH /api/internal/ops/leagues/:leagueID/playoffs`, never with a direct SQL update, so the configuration and draft state are synchronized.
- No completed, active, picked, banned, or protected-repick draft is reclassified. If the dynamically calculated playoff suffix includes one of these drafts, the league remains in the ordinary schedule instead of receiving a partial bracket.

Verification query:

```sql
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('league_playoffs', 'league_playoff_pick_selections')
ORDER BY tablename;
```

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'leagues'
  AND column_name IN ('playoffs_enabled', 'playoff_schedule_anchor_round', 'playoff_schedule_anchor_at')
ORDER BY column_name;
```

Active-draft preflight (add `WHERE cp.league_id = 30` immediately before `GROUP BY` to inspect the example league only):

```sql
WITH active_leagues AS (
    SELECT
        l.id AS league_id,
        l.season_id,
        COALESCE(l.playoff_schedule_anchor_round, l.initial_race_round) AS anchor_round,
        COUNT(lm.id)::int AS player_count
    FROM leagues l
    JOIN league_members lm ON lm.league_id = l.id
WHERE l.status = 'active'
      AND l.playoffs_enabled = true
      AND COALESCE(l.playoff_schedule_anchor_round, l.initial_race_round) IS NOT NULL
    GROUP BY l.id, l.season_id, COALESCE(l.playoff_schedule_anchor_round, l.initial_race_round)
    HAVING COUNT(lm.id) > 0
), playable_races AS (
    SELECT
        al.league_id,
        r.id AS race_id,
        r.round,
        al.player_count,
        ROW_NUMBER() OVER (PARTITION BY al.league_id ORDER BY r.round) AS race_number,
        COUNT(*) OVER (PARTITION BY al.league_id) AS race_count
    FROM active_leagues al
    JOIN races r ON r.season_id = al.season_id
              AND r.round >= al.anchor_round
              AND r.status <> 'cancelled'
), candidate_playoffs AS (
    SELECT *
    FROM playable_races
    WHERE race_count / player_count > 0
      AND race_count % player_count > 0
      AND race_number > race_count - (race_count % player_count)
)
SELECT
    cp.league_id,
    cp.race_id,
    cp.round,
    rd.id AS draft_id,
    rd.current_pick_index,
    COUNT(DISTINCT pp.id)::int AS player_pick_count,
    (
        SELECT COUNT(*)::int
        FROM player_bans pb
        WHERE pb.draft_id = rd.id
    ) AS ban_count
FROM candidate_playoffs cp
JOIN race_drafts rd ON rd.league_id = cp.league_id AND rd.race_id = cp.race_id
LEFT JOIN player_picks pp ON pp.draft_id = rd.id
GROUP BY cp.league_id, cp.race_id, cp.round, rd.id, rd.current_pick_index
HAVING rd.current_pick_index > 0
    OR COUNT(DISTINCT pp.id) > 0
    OR EXISTS (
        SELECT 1
        FROM player_bans pb
        WHERE pb.draft_id = rd.id
    )
ORDER BY cp.league_id, cp.round;
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
