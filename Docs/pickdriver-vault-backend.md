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

### Secure operation

- Internal service auth via `X-Internal-Token`.
- Vault does not depend on end-user JWT.
- Internal routes are isolated under `/api/internal/*`.

### Maintenance integration

- Vault can enable/disable maintenance during restore operations:
  - `POST /api/internal/system/maintenance/enable`
  - `POST /api/internal/system/maintenance/disable`
- Events are logged in `ops_audit_events`.

### Relevant environment variables

- `ENABLE_INTERNAL_ROUTES=true`
- `INTERNAL_SERVICE_TOKEN=<secret>`
- `MAINTENANCE_MODE=false` (recommended default)

### Dedicated backend tests

- `/Users/eduardomelcondiez/Desktop/VSC_PickDriverVapor/PickDriver-VaporAPI/Tests/PickdriverVaporApiTests/PickDriverVaultTests.swift`
  - internal auth on `/api/internal/system/*`
  - `system/info`
  - `system/smoke` (fail and success scenarios)

## Future roadmap (Vault)

### API-managed backup contracts

- Endpoint for recent backup status (metadata).
- Endpoint for backup inventory (retention/expiration).
- Endpoint to run backup verification (checksum/restore checks).

### Disaster recovery workflow

- Endpoint to trigger controlled DR drills.
- Structured post-restore check results.
- Extended backup/restore auditing events.

### Security and compliance

- Signing/encryption for sensitive metadata.
- Service secret rotation policy.
- Future remote storage integration (R2/MinIO/S3-compatible) in Vault backend.

