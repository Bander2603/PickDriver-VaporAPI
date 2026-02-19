# PickDriver API (Vapor) - Web Client Documentation (.NET/Blazor)

## Base URL
- Production: https://api.example.com
- Prefix: /api
- Content-Type: application/json
- Dates: ISO 8601 (UTC)
- JSON keys: camelCase by default (Swift naming). Some DTOs and query params use snake_case; see endpoint/model details.

## Trademark Notice
This project is independent and is not affiliated with or endorsed by Formula 1, the FIA, or related entities. No official logos or brand assets are used. “Formula 1”, “F1”, and related marks belong to their respective owners and are referenced for descriptive purposes only.

## Authentication
- JWT HS256
- Header: Authorization: Bearer <token>
- Expiration: JWT_EXPIRES_IN_SECONDS (default 604800)

## Errors
- Vapor error format: { "error": true, "reason": "..." }
- Common status codes: 400, 401, 403, 404, 409, 500

## Headers and quick example
- Authorization: Bearer <token> (protected routes only)
- Content-Type: application/json
- X-Internal-Token: <token> (internal routes under `/api/internal/*` only)

Example:
```bash
curl -H "Authorization: Bearer <token>" \
  https://api.example.com/api/leagues/my
```

## Recommended authentication flow
1) POST /api/auth/register (requires inviteCode)
2) POST /api/auth/login -> JWT token
3) Send token in Authorization for all remaining protected endpoints

Alternative:
- POST /api/auth/google (Google login/registration; no inviteCode required)
- POST /api/auth/apple (Apple login/registration; no inviteCode required)

Notes:
- No refresh token is implemented; once JWT expires, user must log in again.

## Key validations and business rules
Auth:
- username: 3-20 chars; letters/numbers/._- only
- email: max 100, regex-validated, normalized to lowercase
- password: minimum 8 chars
- update password: cannot be equal to current password
- email/password registration requires inviteCode
- if INVITE_CODE is configured in backend, only that value is accepted
- if INVITE_CODE is not configured, codes are validated against `invite_codes` table (unused codes)
- Google auth requires GOOGLE_CLIENT_ID or GOOGLE_CLIENT_IDS in backend
- Apple auth requires APPLE_CLIENT_ID or APPLE_CLIENT_IDS in backend

Leagues and teams:
- League creation requires an active season.
- Maximum 3 leagues created per user (status "pending" or "active"). Completed/deleted leagues do not count.
- As a member, a player can join any number of leagues.
- Joining allowed only if league status is "pending" and member count does not exceed max_players.
- assign-pick-order and start-draft are owner-only.
- Teams are allowed only when league is "pending" and teams_enabled = true.
- League must be full (memberCount == max_players) to create/update/delete teams.
- Minimum team size: 2; duplicate users and multi-team assignments are not allowed.
- Team count is limited by player count and season F1 teams count.

Draft:
- start-draft creates drafts for upcoming races from initial_race_round.
- pickOrder includes mirrored picks if mirror_picks_enabled = true.
- Deadlines: firstHalfDeadline = fp1 - 36h; secondHalfDeadline = fp1.
- pick/ban is blocked once race has started (raceTime in the past).
- Pick: only current turn user; with teams enabled, in the last hour before fp1 a teammate can pick for current turn.
- Ban: only if bans_enabled = true; only the immediate previous pick can be banned.
- Last player in order cannot be banned (unless also first).
- Remaining bans: 2 per user (no teams) or 3 per team (teams enabled).
- Per-race limit: each user/team can use 1 ban per race; in no-team leagues, a player can only be banned once per race.
- Autopick: if list exists and turn expires, automatic pick is attempted.

Notifications:
- GET /api/notifications: default limit 50, max 100, unread_only default false.
- Register device updates token if it already exists.
- Unregister marks token as inactive.

## Endpoints

### Health (public)
- GET /api/health/live
  - Res: `{ "status": "ok", "service": "pickdriver-vapor-api", "version": String, "uptimeSeconds": Int, "timestamp": Date }`
- GET /api/health/ready
  - Res 200: `{ "status": "ok", "timestamp": Date, "checks": [{ "name": "database", "status": "ok", "latencyMs": Double, "reason": null }] }`
  - Res 503: `{ "status": "fail", "timestamp": Date, "checks": [{ "name": "database", "status": "fail", "latencyMs": null, "reason": String }] }`
- GET /api/health/ping
  - Res: `{ "status": "ok", "serverTime": Date, "uptimeSeconds": Int, "dbStatus": "ok"|"fail", "dbLatencyMs": Double? }`
- GET /api/health/dependencies
  - Res 200/503: `{ "status": "ok"|"fail", "timestamp": Date, "maintenanceMode": Bool, "dependencies": [{ "name": String, "status": "ok"|"warn"|"fail"|"skip", "latencyMs": Double?, "details": String }] }`

### Internal system (internal token)
- GET /api/internal/system/info
  - Required header: `X-Internal-Token`
  - Res: `{ "status": "ok", "service": "pickdriver-vapor-api", "version": String, "environment": String, "timestamp": Date, "uptimeSeconds": Int, "recentMigrations": [{ "name": String, "batch": Int, "createdAt": Date? }] }`
- GET /api/internal/system/smoke
  - Required header: `X-Internal-Token`
  - Res 200: `{ "status": "ok", "timestamp": Date, "checks": [{ "name": String, "status": "ok", "details": String }] }`
  - Res 503: `{ "status": "fail", "timestamp": Date, "checks": [{ "name": String, "status": "fail"|"ok", "details": String }] }`
- POST /api/internal/system/maintenance/enable
  - Required header: `X-Internal-Token`
  - Req (optional): `{ "source": "vault-worker", "reason": "restore drill" }`
  - Res: `{ "status": "ok", "maintenanceMode": true, "changed": Bool, "eventType": String, "auditLogged": Bool, "timestamp": Date }`
- POST /api/internal/system/maintenance/disable
  - Required header: `X-Internal-Token`
  - Req (optional): `{ "source": "vault-worker", "reason": "restore finished" }`
  - Res: `{ "status": "ok", "maintenanceMode": false, "changed": Bool, "eventType": String, "auditLogged": Bool, "timestamp": Date }`

### Internal ops (internal token)
- GET /api/internal/ops/db-info
  - Required header: `X-Internal-Token`
  - Query (optional): `target=drill|staging|primary` (defaults to primary DB)
  - Res: `{ "schemaVersion": String, "lastMigrationAt": Date?, "appliedMigrations": [{ "name": String, "batch": Int, "createdAt": Date? }], "expectedCriticalTables": [String], "criticalTableCounts": { "<table>": Int }? }`
- POST /api/internal/ops/backup/validate
  - Required header: `X-Internal-Token`
  - Req: `{ "target": "drill"|"staging"|"primary", "backupId": String, "checksProfile": "quick"|"full", "source": "vault-worker"?, "reason": String? }`
  - Res: `{ "success": Bool, "checks": [{ "name": String, "status": "ok"|"warn"|"fail", "details": String, "latencyMs": Double? }], "summary": { "passed": Int, "failed": Int, "warnings": Int }, "validatedAtUtc": Date }`

Maintenance notes:
- When `maintenanceMode` is enabled, API returns `503` for `/api/*` routes except `/api/health/*` and `/api/internal/*`.
- Every maintenance toggle is audited in `ops_audit_events`.
- If auditing fails (for example, pending migration for `ops_audit_events`), toggle still returns `200` with `auditLogged=false`.
- Internal routes can enforce HTTPS via `INTERNAL_REQUIRE_HTTPS` (default `true` in production).
- `target=prod|production|main|live` is rejected on internal drill operations.
- `target=drill` requires dedicated DB settings (`DRILL_DB_*`), otherwise API returns `503`.
- Drill DB provisioning reference: `Docs/pickdriver-vault-backend.md` (`Drill DB provisioning` section).
- Backup validation writes drill audit events in `ops_audit_events`:
  - `drill_started`
  - `restore_completed`
  - `functional_validation_completed` or `functional_validation_failed`
  - `drill_finished`

### Auth
- POST /api/auth/register
  - Req: { "username": "user", "email": "a@b.com", "password": "...", "inviteCode": "INVITE" }
  - Res: { "user": UserPublic }
- POST /api/auth/login
  - Req: { "email": "a@b.com", "password": "..." }
  - Res: { "user": UserPublic, "token": "..." }
- POST /api/auth/google
  - Req: { "idToken": "...", "inviteCode": "INVITE"? }
  - Res: { "user": UserPublic, "token": "..." }
  - Note: inviteCode is optional (Google flow does not require invitation).
- POST /api/auth/apple
  - Req: { "idToken": "...", "email": "a@b.com"?, "firstName": "John"?, "lastName": "Doe"?, "inviteCode": "INVITE"? }
  - Res: { "user": UserPublic, "token": "..." }
  - Note: inviteCode is optional. `email` is a fallback when Apple does not include email in subsequent sign-ins.
- GET /api/auth/profile (auth)
  - Res: UserPublic
- PUT /api/auth/password (auth)
  - Req: { "currentPassword": "...", "newPassword": "..." }
  - Res: 200 OK
- PUT /api/auth/username (auth)
  - Req: { "username": "new_name" }
  - Res: UserPublic

### Races (public)
- GET /api/races
  - Res: Race[] (active season only)
- GET /api/races/upcoming
  - Res: Race[] (active season only)
- GET /api/races/current
  - Res: Race (active season only)
- GET /api/races/:raceID
  - Res: Race

### Drivers (public)
- GET /api/drivers
  - Res: Driver[] (active season only)

### F1 Teams (public)
- GET /api/f1/teams
  - Res: F1Team[] (active season only)

### F1 Standings (public)
- GET /api/standings/f1/drivers
  - Res: DriverStanding[] (active season only; includes zero points if no results)
- GET /api/standings/f1/teams
  - Res: TeamStanding[] (active season only; includes zero points if no results)

### Leagues (auth)
- GET /api/leagues/my
  - Res: LeaguePublic[] (active season only)
- POST /api/leagues/create
  - Req: { "name": "...", "maxPlayers": 8, "teamsEnabled": true, "bansEnabled": true, "mirrorEnabled": true }
  - Res: LeaguePublic
- POST /api/leagues/join
  - Req: { "code": "ABC123" }
  - Res: LeaguePublic
- DELETE /api/leagues/:leagueID
  - Res: 200 OK
  - Note: owner only and only if status = "pending".
- GET /api/leagues/:leagueID/members
  - Res: UserPublic[]
- GET /api/leagues/:leagueID/teams
  - Res: LeagueTeam[] (includes members)
- POST /api/leagues/:leagueID/assign-pick-order
  - Res: 200 OK
- POST /api/leagues/:leagueID/start-draft
  - Res: 200 OK
- GET /api/leagues/:leagueID/draft/:raceID/pick-order
  - Res: [Int] (user IDs)
- GET /api/leagues/:leagueID/draft/:raceID
  - Res: RaceDraft (includes pickedDriverIDs, bannedDriverIDs and bannedDriverIDsByPickIndex)
- GET /api/leagues/:leagueID/draft/:raceID/deadlines
  - Res: DraftDeadline
- GET /api/leagues/:leagueID/autopick
  - Res: { "driverIDs": [Int] }
- PUT /api/leagues/:leagueID/autopick
  - Req: { "driverIDs": [Int] }
  - Res: { "driverIDs": [Int] }

### Draft picks (auth)
- POST /api/leagues/:leagueID/draft/:raceID/pick
  - Req: { "driverID": Int }
  - Res: DraftResponse
- POST /api/leagues/:leagueID/draft/:raceID/ban
  - Req: { "targetUserID": Int, "driverID": Int }
  - Res: DraftResponse

### Teams (auth)
- POST /api/teams
  - Req: { "league_id": Int, "name": "...", "user_ids": [Int] }
  - Res: LeagueTeam
- PUT /api/teams/:teamID
  - Req: { "name": "...", "user_ids": [Int] }
  - Res: LeagueTeam
- DELETE /api/teams/:teamID
  - Res: 200 OK
- POST /api/teams/:teamID/assign
  - Req: { "userID": Int }
  - Res: 200 OK

### Player standings (auth)
- GET /api/players/standings/players?league_id=...
  - Res: PlayerStanding[]
- GET /api/players/standings/teams?league_id=...
  - Res: PlayerTeamStanding[]
- GET /api/players/standings/picks?league_id=...&user_id=...
  - Res: PickHistory[]

### Notifications (auth)
- GET /api/notifications?limit=50&unread_only=false
  - Res: PushNotificationPublic[]
- POST /api/notifications/devices
  - Req: { "token": "...", "platform": "...", "deviceID": "..."? }
  - Res: 200 OK
- DELETE /api/notifications/devices
  - Req: { "token": "..." }
  - Res: 200 OK
- POST /api/notifications/:notificationID/read
  - Res: PushNotificationPublic

### Results publish (auth)
- POST /api/races/:raceID/results/publish
  - Res: { "createdNotifications": Int }

## Models (summary)

UserPublic:
{ "id": Int, "username": String, "email": String, "emailVerified": Bool }

LeaguePublic:
{ "id": Int, "name": String, "invite_code": String, "status": String, "initial_race_round": Int?, "owner_id": Int, "max_players": Int, "teams_enabled": Bool, "bans_enabled": Bool, "mirror_picks_enabled": Bool }

Race:
{
  "id": Int, "seasonID": Int, "round": Int, "name": String, "circuitName": String,
  "circuitData": { "laps": Int?, "first_gp": Int?, "race_distance": Double?, "circuit_length": Double?, "lap_record_time": String?, "lap_record_driver": String? }?,
  "country": String, "countryCode": String, "sprint": Bool, "completed": Bool,
  "fp1Time": Date?, "fp2Time": Date?, "fp3Time": Date?, "qualifyingTime": Date?,
  "sprintTime": Date?, "raceTime": Date?, "sprintQualifyingTime": Date?
}

Driver:
{ "id": Int, "seasonID": Int, "teamID": Int, "firstName": String, "lastName": String, "country": String, "driverNumber": Int, "active": Bool, "driverCode": String }

F1Team:
{ "id": Int, "seasonID": Int, "name": String, "color": String }

RaceDraft:
{ "id": Int, "league": { "id": Int }, "raceID": Int, "pickOrder": [Int], "currentPickIndex": Int, "mirrorPicks": Bool, "status": String, "pickedDriverIDs": [Int?], "bannedDriverIDs": [Int], "bannedDriverIDsByPickIndex": [Int?] }
  - pickedDriverIDs is aligned with pickOrder (same length), with null where no active pick exists or pick was banned.
  - bannedDriverIDs includes all driver_id values with is_banned = true in the draft.
  - bannedDriverIDsByPickIndex is aligned with pickOrder (same length); contains the last banned driver for that slot or null if none.

DraftDeadline:
{ "raceID": Int, "leagueID": Int, "firstHalfDeadline": Date, "secondHalfDeadline": Date }

DraftResponse:
{ "status": String, "currentPickIndex": Int, "nextUserID": Int?, "bannedDriverIDs": [Int], "pickedDriverIDs": [Int], "yourTurn": Bool, "yourDeadline": Date }

LeagueTeam:
{ "id": Int, "name": String, "league": { "id": Int }, "members": [TeamMember] }

TeamMember:
{ "id": Int, "user": { "id": Int }, "team": { "id": Int } }

DriverStanding:
{ "driver_id": Int, "first_name": String, "last_name": String, "driver_code": String, "points": Int, "team_id": Int, "team_name": String, "team_color": String }

TeamStanding:
{ "team_id": Int, "name": String, "color": String, "points": Int }

PlayerStanding:
{ "user_id": Int, "username": String, "total_points": Double, "team_id": Int?, "total_deviation": Double }

PlayerTeamStanding:
{ "team_id": Int, "name": String, "total_points": Double, "total_deviation": Double }

PickHistory:
{ "race_name": String, "round": Int, "pick_position": Int, "driver_name": String, "points": Double, "expected_points": Double?, "deviation": Double? }

PushNotificationPublic:
{ "id": Int, "type": String, "title": String, "body": String, "data": NotificationPayload?, "leagueID": Int?, "raceID": Int?, "createdAt": Date?, "readAt": Date?, "deliveredAt": Date? }

NotificationPayload:
{ "leagueID": Int?, "raceID": Int?, "draftID": Int?, "pickIndex": Int? }

## CORS, domain, and Cloudflare
- If client runs on https://pickdriver.cc and API is on another origin (for example, https://api.pickdriver.cc), browser requires CORS.
- CORSMiddleware is currently not configured.
- Recommendation: allow CORS for https://pickdriver.cc (+ www and staging if needed) and allow Authorization and Content-Type headers.
- If API is proxied under same origin (pickdriver.cc/api), CORS is not needed.
- Cloudflare DNS/proxy does not break auth by itself, but avoid caching authenticated routes and ensure Authorization headers are forwarded unchanged.
