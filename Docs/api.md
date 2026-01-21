# PickDriver API (Vapor) - Documentacion para cliente web (.NET/Blazor)

## Base URL
- Produccion: https://api.pickdriver.cc
- Prefijo: /api
- Content-Type: application/json
- Fechas: ISO 8601 (UTC)
- JSON keys: snake_case (Vapor default)

## Autenticacion
- JWT HS256
- Header: Authorization: Bearer <token>
- Expiracion: JWT_EXPIRES_IN_SECONDS (default 604800)
- Login requiere email verificado

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
1) POST /api/auth/register
2) POST /api/auth/verify-email (token recibido por email)
3) POST /api/auth/login -> token JWT
4) Enviar token en Authorization para el resto de endpoints protegidos

Notas:
- El login falla si el email no esta verificado.
- No hay refresh token; cuando expira el JWT, se re-login.

## Validaciones y reglas de negocio clave
Auth:
- username: 3-50 caracteres; solo letras/numeros/._-
- email: max 100, validacion por regex, se normaliza a lowercase
- password: minimo 8 caracteres
- update password: no puede ser igual a la actual
- resend verification: en produccion se limita por EMAIL_VERIFICATION_RESEND_INTERVAL_SECONDS

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
- pick_order incluye mirror picks si mirror_picks_enabled = true.
- Deadlines: first_half_deadline = fp1 - 36h; second_half_deadline = fp1.
- No se permite pick/ban si la carrera ya comenzo (race_time en pasado).
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
  - Req: { "username": "user", "email": "a@b.com", "password": "..." }
  - Res: { "user": UserPublic, "verification_required": true, "verification_token": "..."? }
  - Nota: verification_token solo en no-produccion.
- POST /api/auth/login
  - Req: { "email": "a@b.com", "password": "..." }
  - Res: { "user": UserPublic, "token": "..." }
- POST /api/auth/verify-email
  - Req: { "token": "..." }
  - Res: { "verified": true }
- POST /api/auth/resend-verification
  - Req: { "email": "a@b.com" }
  - Res: { "message": "...", "verification_token": "..."? }
- GET /api/auth/profile (auth)
  - Res: UserPublic
- PUT /api/auth/password (auth)
  - Req: { "current_password": "...", "new_password": "..." }
  - Res: 200 OK

### Races (publico)
- GET /api/races
- GET /api/races/upcoming
- GET /api/races/current
- GET /api/races/:race_id
  - Res: Race

### Drivers (publico)
- GET /api/drivers
  - Res: Driver

### Standings F1 (publico)
- GET /api/standings/f1/drivers
  - Res: DriverStanding[]
- GET /api/standings/f1/teams
  - Res: TeamStanding[]

### Leagues (auth)
- GET /api/leagues/my
  - Res: LeaguePublic[]
- POST /api/leagues/create
  - Req: { "name": "...", "max_players": 8, "teams_enabled": true, "bans_enabled": true, "mirror_picks_enabled": true }
  - Res: LeaguePublic
- POST /api/leagues/join
  - Req: { "code": "ABC123" }
  - Res: LeaguePublic
- GET /api/leagues/:league_id/members
  - Res: UserPublic[]
- GET /api/leagues/:league_id/teams
  - Res: LeagueTeam[] (incluye members)
- POST /api/leagues/:league_id/assign-pick-order
  - Res: 200 OK
- POST /api/leagues/:league_id/start-draft
  - Res: 200 OK
- GET /api/leagues/:league_id/draft/:race_id/pick-order
  - Res: [Int] (user_id)
- GET /api/leagues/:league_id/draft/:race_id
  - Res: RaceDraft
- GET /api/leagues/:league_id/draft/:race_id/deadlines
  - Res: DraftDeadline
- GET /api/leagues/:league_id/autopick
  - Res: { "driver_ids": [Int] }
- PUT /api/leagues/:league_id/autopick
  - Req: { "driver_ids": [Int] }
  - Res: { "driver_ids": [Int] }

### Draft picks (auth)
- POST /api/leagues/:league_id/draft/:race_id/pick
  - Req: { "driver_id": Int }
  - Res: DraftResponse
- POST /api/leagues/:league_id/draft/:race_id/ban
  - Req: { "target_user_id": Int, "driver_id": Int }
  - Res: DraftResponse

### Teams (auth)
- POST /api/teams
  - Req: { "league_id": Int, "name": "...", "user_ids": [Int] }
  - Res: LeagueTeam
- PUT /api/teams/:team_id
  - Req: { "name": "...", "user_ids": [Int] }
  - Res: LeagueTeam
- DELETE /api/teams/:team_id
  - Res: 200 OK
- POST /api/teams/:team_id/assign
  - Req: { "user_id": Int }
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
  - Req: { "token": "...", "platform": "...", "device_id": "..."? }
  - Res: 200 OK
- DELETE /api/notifications/devices
  - Req: { "token": "..." }
  - Res: 200 OK
- POST /api/notifications/:notification_id/read
  - Res: PushNotificationPublic

### Results publish (auth)
- POST /api/races/:race_id/results/publish
  - Res: { "created_notifications": Int }

## Modelos (resumen)

UserPublic:
{ "id": Int, "username": String, "email": String, "email_verified": Bool }

LeaguePublic:
{ "id": Int, "name": String, "invite_code": String, "status": String, "initial_race_round": Int?, "owner_id": Int, "max_players": Int, "teams_enabled": Bool, "bans_enabled": Bool, "mirror_picks_enabled": Bool }

Race:
{
  "id": Int, "season_id": Int, "round": Int, "name": String, "circuit_name": String,
  "circuit_data": { "laps": Int?, "first_gp": Int?, "race_distance": Double?, "circuit_length": Double?, "lap_record_time": String?, "lap_record_driver": String? }?,
  "country": String, "country_code": String, "sprint": Bool, "completed": Bool,
  "fp1_time": Date?, "fp2_time": Date?, "fp3_time": Date?, "qualifying_time": Date?,
  "sprint_time": Date?, "race_time": Date?, "sprint_qualifying_time": Date?
}

Driver:
{ "id": Int, "season_id": Int, "f1_team_id": Int, "first_name": String, "last_name": String, "country": String, "driver_number": Int, "active": Bool, "driver_code": String }

RaceDraft:
{ "id": Int, "league_id": Int, "race_id": Int, "pick_order": [Int], "current_pick_index": Int, "mirror_picks": Bool, "status": String }

DraftDeadline:
{ "race_id": Int, "league_id": Int, "first_half_deadline": Date, "second_half_deadline": Date }

DraftResponse:
{ "status": String, "current_pick_index": Int, "next_user_id": Int?, "banned_driver_ids": [Int], "picked_driver_ids": [Int], "your_turn": Bool, "your_deadline": Date }

LeagueTeam:
{ "id": Int, "name": String, "league_id": Int, "members": [TeamMember] }

TeamMember:
{ "id": Int, "user_id": Int, "team_id": Int }

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
{ "id": Int, "type": String, "title": String, "body": String, "data": NotificationPayload?, "league_id": Int?, "race_id": Int?, "created_at": Date?, "read_at": Date?, "delivered_at": Date? }

NotificationPayload:
{ "league_id": Int?, "race_id": Int?, "draft_id": Int?, "pick_index": Int? }

## CORS, dominio y Cloudflare
- Si el cliente vive en https://pickdriver.cc y la API en otro origen (ej. https://api.pickdriver.cc), el navegador requiere CORS.
- Actualmente no hay CORSMiddleware configurado.
- Sugerencia: habilitar CORS para https://pickdriver.cc (+ www y staging si aplica) y permitir headers Authorization y Content-Type.
- Si se hace proxy de la API bajo el mismo origen (pickdriver.cc/api), no hace falta CORS.
- Cloudflare DNS/proxy no rompe auth, pero evitar cachear rutas autenticadas y asegurar que Authorization pase intacto.
