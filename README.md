# PickdriverVaporApi

Backend API for a fantasy F1 draft league platform. Built with Vapor + Fluent + Postgres, with JWT auth, league/draft logic, standings, and notifications.

## Highlights
- JWT auth (email/password) + Google sign-in
- Leagues, teams, drafts, bans, autopicks
- Standings and race results publishing
- Notifications and device registration
- Extensive integration tests

## Tech stack
- Swift 6
- Vapor 4
- Fluent + Postgres
- JWT

## Project structure
- `Sources/PickdriverVaporApi`: app code (controllers, models, services, migrations)
- `Tests/PickdriverVaporApiTests`: integration tests
- `docs/`: API and business-logic notes

## Local setup
1) Copy env file:
```bash
cp .env.example .env
```
2) Start Postgres:
```bash
docker compose up db
```
3) Run migrations:
```bash
swift run PickdriverVaporApi migrate --yes
```
4) Run the server:
```bash
swift run
```

## Environment variables
See `.env.example` for the full list. Key values:
- `JWT_SECRET` (required)
- `DATABASE_*` (required)
- `DATABASE_TLS_MODE` (`disable`, `prefer`, `require`)
  - Default is `require` in production, `disable` otherwise
- `GOOGLE_CLIENT_ID` (optional)
- `INVITE_CODE` (optional)
- `ENABLE_INTERNAL_ROUTES` (optional, default `true`)
- `INTERNAL_SERVICE_TOKEN` (required only when `ENABLE_INTERNAL_ROUTES=true`)
- `INTERNAL_REQUIRE_HTTPS` (optional; defaults to `true` in production)
- `DRILL_DB_*` (optional; dedicated drill DB used by `/api/internal/ops/*` when `target=drill`)

## Environment profiles
Use separate env files to avoid mixing runtime and test databases:

- `.env.test.example` -> copy to `.env.test` (for `swift test`)

Create them once:
```bash
cp .env.test.example .env.test
```

Load a profile in the current shell:
```bash
set -a; source .env.test; set +a
```
For PM2/runtime, use `.env` (including `DRILL_DB_*`).
Always load the profile right before running the command (`test`) to avoid stale variables.

## Drill database provisioning
If you use PickDriver Vault DR validations, provision a dedicated drill database and user:

```sql
CREATE ROLE pickdriver_drill_user LOGIN PASSWORD 'change_me';
CREATE DATABASE pickdriver_drill OWNER pickdriver_drill_user;
```

Then migrate that DB once using runtime `.env` values.
Full step-by-step guide: `Docs/pickdriver-vault-backend.md` (`Drill DB provisioning` section).

## Running Without PickDriver Ops / PickDriver Vault
This repository can run as a standalone API without the internal Ops/Vault integrations.

- Set `ENABLE_INTERNAL_ROUTES=false` to disable all `/api/internal/*` endpoints.
- When internal routes are disabled, `INTERNAL_SERVICE_TOKEN` is not required.
- Public/auth/gameplay routes continue to work normally.
- `ops_audit_events` migration may still exist in the schema; this is safe to ignore if you do not use Ops/Vault.

Recommended standalone startup:
```bash
ENABLE_INTERNAL_ROUTES=false swift run
```

## Tests
```bash
swift test
```
Note: tests require `DATABASE_NAME` to include "test".
Note: some integration tests target internal Ops/Vault routes and expect `ENABLE_INTERNAL_ROUTES=true`.
Recommended:
```bash
set -a; source .env.test; set +a
swift test --filter PickDriverVaultTests -v
```

## Docs
- `docs/api.md`: endpoint list and contract
- `docs/logic.md`: business rules

## Trademarks
This project is unofficial and not affiliated with, endorsed by, or sponsored by Formula 1, the FIA, or any related entities. It does not use any official logos or brand assets. “Formula 1”, “F1”, and related marks are trademarks of their respective owners and are used here only for descriptive purposes.

## License
MIT. See `LICENSE`.
