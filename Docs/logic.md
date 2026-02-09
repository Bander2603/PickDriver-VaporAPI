# Business Logic - PickDriver API (Vapor)

This document summarizes the actual rules implemented in the API for leagues, draft flow, picks, teams, and standings.

## General conventions
- JSON: camelCase by default; some endpoints use snake_case in payloads and query params.
- All league/draft/pick routes require JWT (Authorization: Bearer).
- Validations are enforced at runtime; there are no hidden rules outside the codebase.

## Trademark notice
This project is independent and is not affiliated with or endorsed by Formula 1, the FIA, or related entities. No official logos or brand assets are used. “Formula 1”, “F1”, and related marks belong to their respective owners and are referenced for descriptive purposes only.

## Leagues
### Creation
- Requires an active season (`season.active = true`). Otherwise returns 400.
- League is created with status `pending`.
- Creator becomes owner and is also added as a member.
- `teamsEnabled`, `bansEnabled`, and `mirrorEnabled` are accepted without extra validation at creation time.
- `maxPlayers` sets the member limit.

### Joining a league
- Allowed only while league status is `pending`.
- Joining is blocked if user is already a member.
- Joining is blocked when league is full (`memberCount >= maxPlayers`).

### Permissions
- `owner` (creator) is the only role allowed to:
  - assign pick order (`assign-pick-order`)
  - start draft (`start-draft`)
  - delete league (only while `pending`)
- Several operations also require the user to be a league member (see protected endpoints).

### Delete league
- Owner only.
- Only while league is `pending`.
- Delete cascades through members, teams, drafts, picks, and autopicks via FK rules.

## Teams
### Enablement rules
- Applies only when `teamsEnabled = true`.
- League must be in `pending`.
- League must be full (`memberCount == maxPlayers`).

### Team-size rules
- Minimum team size: 2.
- Maximum team count = `min(totalPlayers / 2, numberOfSeasonF1Teams)`.
- Distribution must be feasible and balanced:
  - each team size must be between `floor(totalPlayers / k)` and `ceil(totalPlayers / k)`
  - teams below minimum size are not allowed

### Membership rules
- Duplicate users inside the same team are not allowed.
- A user cannot be assigned to multiple teams.
- Only league members can be assigned to teams.

## Drafts
### Activation (start-draft)
- Owner only.
- League must be `pending`.
- League must be full (`members == maxPlayers`).
- If `teamsEnabled = true`, all players must be assigned to teams.

### Pick order
- If full `pickOrder` was assigned for all members, it is used as-is.
- Otherwise a random order is computed:
  - without teams: direct shuffle
  - with teams: team shuffle + round-robin between teams
- For each upcoming race from `initialRaceRound`, order is rotated.
- If `mirrorEnabled = true`, order is duplicated with mirror logic (`rotated + reversed`).

### Deadlines
- `firstHalfDeadline = fp1Time - 36h`
- `secondHalfDeadline = fp1Time`
- If `fp1Time` is missing or no draft exists for race, returns 404.

## Autopick
- Each user can save an ordered driver list (`driverIDs`) per league.
- Duplicates are removed while preserving order.
- List must match league season drivers.
- Empty list removes autopick configuration.
- When turn expires, autopick tries first available driver:
  - not banned by that user
  - not already picked by another player
- If no valid autopick exists, turn expires and flow advances anyway.

## Picks
### Access rules
- Only current turn user can pick.
- If `teamsEnabled = true` and less than 1h remains before fp1, a teammate can pick for the current turn.

### Validations
- pick/ban is blocked if race already started or completed:
  - `race.completed == true` or `race.raceTime < now`
- Driver must exist and belong to race season.
- Picking an already-picked driver is blocked (global within draft).
- Picking a driver banned by that user is blocked.
- Only one pick per user and per mirror slot (`is_mirror_pick`).

### Effects
- Inserts pick and advances `currentPickIndex`.
- Notifies next player when applicable.

## Bans
### Access rules
- Only if `bansEnabled = true`.
- Only immediate previous pick can be banned.
- Last player in order cannot be banned (unless also first).
- No-team leagues:
  - each user can ban only once per race
  - each player can only be banned once per race
- Team leagues:
  - each team can ban only once per race
- Permissions:
  - no teams: current turn user only
  - teams: current turn user or teammate

### Ban count
- No teams: 2 bans per user.
- Teams enabled: 3 bans per team.
- Per-race restriction: each user/team can use one ban per race; in no-team leagues, a player can only be banned once per race.

### Effects
- Marks pick as banned (`is_banned = true`) and stores `banned_by`.
- Moves `currentPickIndex` back to previous pick so user can re-pick.
- Notifies next player after state change.

## Standings and scoring
- Only non-banned picks are counted.
- Autopicks are worth 50% of driver points.
- Standings are computed over completed races.
- For mirrored picks, position calculation considers mirror order.

## Draft-related notifications
- Starting draft notifies first user in order.
- Completing a pick notifies next user.
- Publishing results creates race-linked notifications.
