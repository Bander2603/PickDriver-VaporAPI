# PickDriver Ops Backend Status and Roadmap

This document describes the current backend status for `PickDriver Ops` and the future implementation roadmap.

## Current implementation (backend API)

### Health and dependency endpoints

- `GET /api/health/live`
  - Process status, version, and uptime.
- `GET /api/health/ready`
  - Readiness check including database availability.
  - Returns `503` if a critical dependency fails.
- `GET /api/health/ping`
  - Synthetic latency and DB status.
- `GET /api/health/dependencies`
  - Dependency-level status (`database`, `draft_deadline_task`, `internal_service_auth`, `maintenance_mode`).
  - Returns `503` when there is a critical failure.

### Internal operation (service-to-service token)

- Required header: `X-Internal-Token`
- Internal auth is separated from end-user JWT auth.
- Controlled by:
  - `ENABLE_INTERNAL_ROUTES=true`
  - `INTERNAL_SERVICE_TOKEN=<secret>`

### Maintenance mode

- `POST /api/internal/system/maintenance/enable`
- `POST /api/internal/system/maintenance/disable`
- When maintenance is active:
  - `/api/*` routes return `503`
  - exceptions: `/api/health/*` and `/api/internal/*`

### Operational auditing

- Table: `public.ops_audit_events`
- Maintenance toggles are logged as operational events.
- If auditing fails, toggle still succeeds:
  - response remains `200`
  - payload includes `auditLogged=false`

### Relevant environment variables

- `APP_VERSION`
- `ENABLE_INTERNAL_ROUTES`
- `INTERNAL_SERVICE_TOKEN`
- `MAINTENANCE_MODE`
- `DATABASE_*`
- `JWT_SECRET` (required for API startup)

### Dedicated backend tests

- `/Users/eduardomelcondiez/Desktop/VSC_PickDriverVapor/PickDriver-VaporAPI/Tests/PickdriverVaporApiTests/PickDriverOpsTests.swift`
  - health endpoints
  - dependencies
  - maintenance mode
  - `ops_audit_events` auditing

## Future roadmap (Ops)

### Advanced observability

- OpenTelemetry instrumentation in API:
  - request traces
  - DB spans
  - log/trace correlation
- Prometheus/OpenMetrics metrics exposure.
- Operational dashboards (Grafana) with p95/p99 per endpoint.

### Anomaly alerts (baseline/P95)

- Baseline per endpoint and time window.
- Anomaly rules based on deviation vs historical P95.
- Lower false positives versus fixed-threshold alerting.

### PickDriver Ops UX improvements (Blazor)

- Progressive degradation view (not only up/down).
- Anomaly timeline with dependency context.
- Endpoint-level drill-down by time window.

