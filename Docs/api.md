# PickDriver API (Vapor) - Documentacion para cliente web (.NET/Blazor)

## Base URL
- Produccion: https://api.pickdriver.cc
- Prefijo: /api
- Content-Type: application/json
- Fechas: ISO 8601 (UTC)
- JSON keys: camelCase por defecto (nombres Swift). Algunos DTOs y query params usan snake_case; ver endpoints/modelos.

## Autenticacion
- JWT HS256
- Header: Authorization: Bearer <token>
- Expiracion: JWT_EXPIRES_IN_SECONDS (default 604800)

## Errores
- Formato (Vapor): { "error": true, "reason": "..." }
- Codigos frecuentes: 400, 401, 403, 404, 409, 500

## Headers y ejemplo rapido
- Authorization: Bearer <token> (solo rutas protegidas)
- Content-Type: application/json

Ejemplo:
```bash
curl -H "Authorization: Bearer <token>" \
  https://api.pickdriver.cc/api/leagues/my
```

## Flujo de autenticacion recomendado
1) POST /api/auth/register (requiere inviteCode)
2) POST /api/auth/login -> token JWT
3) Enviar token en Authorization para el resto de endpoints protegidos

Alternativa:
- POST /api/auth/google (login/registro con Google; no requiere inviteCode)

Notas:
- No hay refresh token; cuando expira el JWT, se re-login.

## Validaciones y reglas de negocio clave
Auth:
- username: 3-50 caracteres; solo letras/numeros/._-
- email: max 100, validacion por regex, se normaliza a lowercase
- password: minimo 8 caracteres
- update password: no puede ser igual a la actual
- register con email/password requiere inviteCode (codigo de invitacion)
- si INVITE_CODE esta configurado en el backend, solo ese codigo es valido
- si INVITE_CODE no existe, se validan codigos en tabla `invite_codes` (no usados)
- Google auth: requiere GOOGLE_CLIENT_ID en el backend

Ligas y equipos:
- Crear liga requiere temporada activa.
- Unirse solo si la liga esta en status "pending" y no supera max_players.
- assign-pick-order y start-draft: solo owner.
- Equipos solo si la liga esta "pending" y teams_enabled = true.
- La liga debe estar completa (memberCount == max_players) para crear/editar/borrar equipos.
- Tamano minimo de equipo: 2; no permite usuarios duplicados ni en multiples equipos.
- Maximo de equipos: limitado por cantidad de jugadores y equipos F1 de la temporada.

Draft:
- start-draft crea drafts para carreras futuras desde initial_race_round.
- pickOrder incluye mirror picks si mirror_picks_enabled = true.
- Deadlines: firstHalfDeadline = fp1 - 36h; secondHalfDeadline = fp1.
- No se permite pick/ban si la carrera ya comenzo (raceTime en pasado).
- Pick: solo el usuario del turno; en ligas con equipos, en la ultima hora antes de fp1 un companero puede pickear por el turno actual.
- Ban: solo si bans_enabled = true; solo se puede banear el pick inmediatamente anterior.
- No se puede banear al ultimo jugador del orden (salvo que sea tambien el primero).
- Bans restantes: 2 por usuario o 3 por equipo (si teams_enabled).
- Autopick: si hay lista y vence el turno, se intenta pick automatico.

Notificaciones:
- GET /api/notifications: limit default 50, max 100, unread_only default false.
- Registrar device actualiza el token si ya existe.
- Unregister marca el token como inactivo.

## Endpoints

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
  - Nota: inviteCode es opcional (Google no requiere invitacion).
- GET /api/auth/profile (auth)
  - Res: UserPublic
- PUT /api/auth/password (auth)
  - Req: { "currentPassword": "...", "newPassword": "..." }
  - Res: 200 OK

### Races (publico)
- GET /api/races
  - Res: Race[]
- GET /api/races/upcoming
  - Res: Race[]
- GET /api/races/current
  - Res: Race
- GET /api/races/:raceID
  - Res: Race

### Drivers (publico)
- GET /api/drivers
  - Res: Driver[]

### Standings F1 (publico)
- GET /api/standings/f1/drivers
  - Res: DriverStanding[]
- GET /api/standings/f1/teams
  - Res: TeamStanding[]

### Leagues (auth)
- GET /api/leagues/my
  - Res: LeaguePublic[]
- POST /api/leagues/create
  - Req: { "name": "...", "maxPlayers": 8, "teamsEnabled": true, "bansEnabled": true, "mirrorEnabled": true }
  - Res: LeaguePublic
- POST /api/leagues/join
  - Req: { "code": "ABC123" }
  - Res: LeaguePublic
- DELETE /api/leagues/:leagueID
  - Res: 200 OK
  - Nota: solo owner y solo si status = "pending".
- GET /api/leagues/:leagueID/members
  - Res: UserPublic[]
- GET /api/leagues/:leagueID/teams
  - Res: LeagueTeam[] (incluye members)
- POST /api/leagues/:leagueID/assign-pick-order
  - Res: 200 OK
- POST /api/leagues/:leagueID/start-draft
  - Res: 200 OK
- GET /api/leagues/:leagueID/draft/:raceID/pick-order
  - Res: [Int] (user IDs)
- GET /api/leagues/:leagueID/draft/:raceID
  - Res: RaceDraft (incluye pickedDriverIDs, bannedDriverIDs y bannedDriverIDsByPickIndex)
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

## Modelos (resumen)

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

RaceDraft:
{ "id": Int, "league": { "id": Int }, "raceID": Int, "pickOrder": [Int], "currentPickIndex": Int, "mirrorPicks": Bool, "status": String, "pickedDriverIDs": [Int?], "bannedDriverIDs": [Int], "bannedDriverIDsByPickIndex": [Int?] }
  - pickedDriverIDs esta alineado con pickOrder (mismo largo), con null si no hay pick vigente o fue baneado.
  - bannedDriverIDs contiene todos los driver_id con is_banned = true para el draft.
  - bannedDriverIDsByPickIndex esta alineado con pickOrder (mismo largo); contiene el ultimo driver baneado para esa posicion o null si no hay baneos.

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

## CORS, dominio y Cloudflare
- Si el cliente vive en https://pickdriver.cc y la API en otro origen (ej. https://api.pickdriver.cc), el navegador requiere CORS.
- Actualmente no hay CORSMiddleware configurado.
- Sugerencia: habilitar CORS para https://pickdriver.cc (+ www y staging si aplica) y permitir headers Authorization y Content-Type.
- Si se hace proxy de la API bajo el mismo origen (pickdriver.cc/api), no hace falta CORS.
- Cloudflare DNS/proxy no rompe auth, pero evitar cachear rutas autenticadas y asegurar que Authorization pase intacto.
