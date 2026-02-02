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

## Tests
```bash
swift test
```
Note: tests require `DATABASE_NAME` to include "test".

## Docs
- `docs/api.md`: endpoint list and contract
- `docs/logic.md`: business rules

## Trademarks
This project is unofficial and not affiliated with, endorsed by, or sponsored by Formula 1, the FIA, or any related entities. It does not use any official logos or brand assets. “Formula 1”, “F1”, and related marks are trademarks of their respective owners and are used here only for descriptive purposes.

## License
MIT. See `LICENSE`.
