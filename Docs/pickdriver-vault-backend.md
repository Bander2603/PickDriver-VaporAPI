# PickDriver Vault Backend Status and Roadmap

This document describes the current backend status for `PickDriver Vault` and the planned roadmap.

## Current implementation (backend API)

### Internal endpoints currently available for Vault

- `GET /api/internal/system/info`
  - Version, environment, uptime, and latest migrations.
  - Use case: compatibility validation before/after restore.
- `GET /api/internal/system/smoke`
  - Read-only checks:
    - DB connectivity
    - active season exists
    - race catalog is available
    - migration history is available
  - Use case: automatic verification during disaster recovery drills.
- `GET /api/internal/ops/db-info`
  - Schema fingerprint, latest migration timestamp, applied migrations and critical table counts.
  - Supports `target=drill` query param to inspect dedicated drill DB.
  - Use case: schema/consistency snapshots before and after restore.
- `POST /api/internal/ops/backup/validate`
  - Validates restored backup with `quick` or `full` profile.
  - Supports `target=drill` using a dedicated drill DB connection.
  - Use case: post-restore functional verification and drill reporting.

### Secure operation

- Internal service auth via `X-Internal-Token`.
- Vault does not depend on end-user JWT.
- Internal routes are isolated under `/api/internal/*`.
- HTTPS can be enforced for internal routes (`INTERNAL_REQUIRE_HTTPS`; defaults to enabled in production).
- Restricted targets (`prod`, `production`, `main`, `live`) are rejected on drill operations.

### Maintenance integration

- Vault can enable/disable maintenance during restore operations:
  - `POST /api/internal/system/maintenance/enable`
  - `POST /api/internal/system/maintenance/disable`
- Events are logged in `ops_audit_events`.
- Backup drill events are logged as:
  - `drill_started`
  - `restore_completed`
  - `functional_validation_completed` / `functional_validation_failed`
  - `drill_finished`

### Relevant environment variables

- `ENABLE_INTERNAL_ROUTES=true`
- `INTERNAL_SERVICE_TOKEN=<secret>`
- `MAINTENANCE_MODE=false` (recommended default)
- `INTERNAL_REQUIRE_HTTPS=true` (recommended in production)
- `DRILL_DB_HOST`, `DRILL_DB_PORT`, `DRILL_DB_NAME`, `DRILL_DB_USER`/`DRILL_DB_USERNAME`, `DRILL_DB_PASSWORD`
- `DRILL_DB_SSLMODE` (`disable`, `prefer`, `require`)

### Drill DB provisioning

Use a dedicated DB (for example `pickdriver_drill`) that is independent from CI/test databases.

Create role and database (run as Postgres superuser):

```sql
CREATE ROLE pickdriver_drill_user LOGIN PASSWORD 'change_me';
CREATE DATABASE pickdriver_drill OWNER pickdriver_drill_user;
REVOKE ALL ON DATABASE pickdriver_drill FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE pickdriver_drill TO pickdriver_drill_user;
```

Configure dedicated env vars:

```env
DRILL_DB_HOST=127.0.0.1
DRILL_DB_PORT=5432
DRILL_DB_NAME=pickdriver_drill
DRILL_DB_USER=pickdriver_drill_user
DRILL_DB_PASSWORD=change_me
DRILL_DB_SSLMODE=disable

ENABLE_INTERNAL_ROUTES=true
INTERNAL_SERVICE_TOKEN=change_me
```

Apply migrations to drill DB:

```bash
DATABASE_HOST=$DRILL_DB_HOST \
DATABASE_PORT=$DRILL_DB_PORT \
DATABASE_NAME=$DRILL_DB_NAME \
DATABASE_USERNAME=$DRILL_DB_USER \
DATABASE_PASSWORD=$DRILL_DB_PASSWORD \
DATABASE_TLS_MODE=$DRILL_DB_SSLMODE \
JWT_SECRET=local-dev-secret \
swift run PickdriverVaporApi migrate --yes
```

### Dedicated backend tests

- `/Users/eduardomelcondiez/Desktop/VSC_PickDriverVapor/PickDriver-VaporAPI/Tests/PickdriverVaporApiTests/PickDriverVaultTests.swift`
  - internal auth on `/api/internal/system/*`
  - `system/info`
  - `system/smoke` (fail and success scenarios)
  - `ops/db-info`
  - `ops/backup/validate` (`quick` and `full`)
  - HTTPS enforcement for internal routes

## Future roadmap (Vault)

### API-managed backup contracts

- Endpoint for recent backup status (metadata).
- Endpoint for backup inventory (retention/expiration).

### Disaster recovery workflow

- Endpoint to trigger controlled DR drills.
- Structured post-restore check results. (implemented via `/api/internal/ops/backup/validate`)
- Extended backup/restore auditing events. (implemented for drill lifecycle)

### Security and compliance

- Signing/encryption for sensitive metadata.
- Service secret rotation policy.
- Future remote storage integration (R2/MinIO/S3-compatible) in Vault backend.
