# Business Logic - PickDriver API (Vapor)

This document summarizes the actual rules implemented in the API for leagues, draft flow, picks, teams, and standings.

## General conventions
- JSON: camelCase by default; some endpoints use snake_case in payloads and query params.
- All league/draft/pick routes require JWT (Authorization: Bearer).
- Validations are enforced at runtime; there are no hidden rules outside the codebase.

## Account deletion
- Endpoint: `DELETE /api/auth/account` (authenticated).
- Deletion is soft-delete (`users.deleted_at`), not hard-delete, to preserve draft/history integrity.
- Pending leagues:
  - if user is owner, the pending league is deleted automatically
  - if user is a non-owner member, membership is removed (slot is freed)
- Active leagues:
  - membership is preserved
  - username is anonymized with a deleted-user label (`(usuario borrado)`) for display continuity
- Credentials and identity links are invalidated on deletion:
  - password hash is replaced
  - Google/Apple IDs are removed
  - verification/reset tokens are cleared
  - push tokens are deactivated
- Deleted users cannot authenticate again with existing JWTs.

## Social identity linking
- An Apple identity already stored in `users.apple_id` is resolved by the verified Apple subject and does not require a repeated email claim.
- A new Apple subject can create or link an account only from a verified email claim contained in the signed Apple identity token.
- The optional `email` sent by a client is ignored for identity resolution and can never be used to claim an existing account.

## Global race administration
- Race reads remain public under `/api/races/*`.
- Publishing results and cancelling a race are global administrative mutations available only under `/api/internal/races/*`.
- They require the internal service token and the configured internal HTTPS policy; end-user JWTs do not authorize these operations.

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

### Playoffs
- Playoffs are opt-in per league through `leagues.playoffs_enabled`; it defaults to `false` and is changed only through the internal administrative endpoint. The public league payload exposes the flag so every client reads league options from one place.
- The playoff calendar is anchored to the first effective draft race (`playoff_schedule_anchor_round`, set when `start-draft` succeeds). A league created after a season has started therefore only counts races it could actually draft; it never counts earlier season races.
- Count the non-cancelled races from that anchor and the league players (`P`).
- At least one complete regular rotation is required. If the schedule has `R` playable races and `R / P == 0`, no playoffs are created. Otherwise, the final `R % P` races are playoffs; a zero remainder means no playoffs.
- Enabling the option after activation immediately creates or reclassifies only the still-pristine future playoff drafts. If the computed playoff suffix includes a completed, in-progress, picked, banned, or protected-repick draft, no partial suffix is created and historical drafts remain regular.
- The calendar is synchronized while no player has selected a playoff position, so added or cancelled races (including an FP1 change) can still move the boundary and deadline. A recalculation is applied only when every affected playoff draft is pristine; the first player choice freezes the bracket. Later calendar changes do not rewrite player choices or completed/in-progress drafts.
- Disabling is allowed only before a playoff pick-position selection or playoff draft activity exists; finalized brackets cannot be disabled.
- A cancelled race never consumes a regular rotation. Consecutive cancelled drafts retain the same calculated order as the next playable race for historical consistency; future unstarted drafts are recalculated when a race is added or cancelled.
- Once every regular-season race has published results, standings are frozen for playoff seeding. Players are sorted by total points descending; ties use `userID` ascending. The top group has `ceil(P / 2)` players and the lower group has the remainder.
- Teams are ignored for playoff ordering. Players choose an unused absolute pick position in their own group, one at a time in seeded order. The final player receives the only remaining position in their group automatically.
- The selection deadline is `24h` before FP1 of the first playoff race. At or after that deadline, all still-unselected positions are assigned randomly within their groups and the order is finalized.
- The first playoff draft uses `topGroup + bottomGroup`. Subsequent drafts rotate each group independently by one place. With mirror enabled, each playoff draft is `topGroup + bottomGroup + topGroup.reversed() + bottomGroup.reversed()`; it does not reverse the combined group order.
- Since the pick-position deadline (FP1 - 24h) is later than a regular first-half draft deadline (FP1 - 36h), every slot of the first playoff draft remains manually playable until FP1. Later playoff drafts use the normal deadline split.
- Picks, bans, protected repicks, deleted-user skips, autopick scoring, and race-start blocking retain their existing draft behavior after the playoff order has been finalized.

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
- If a turn belongs to a deleted user, it is always treated as missed pick and skipped immediately.

## Picks
### Access rules
- Only current turn user can pick.
- If `teamsEnabled = true` and less than 1h remains before fp1, a teammate can pick for the current turn.
- Pick actions are serialized per draft with DB transaction + draft row lock (`FOR UPDATE`) to avoid concurrent inconsistencies.
- A user can edit their already-submitted pick only while their draft slot is still active:
  - they are the immediate previous slot (`currentPickIndex - 1`)
  - their slot deadline has not passed
  - the next slot has not submitted a valid pick yet
- Once the next slot is effectively resolved (turn advanced), editing the previous pick is rejected.

### Validations
- pick/ban is blocked if race already started or completed:
  - `race.completed == true` or `race.raceTime < now`
- Driver must exist and belong to race season.
- Picking an already-picked driver is blocked (global within draft).
- Picking a driver banned by that user is blocked.
- Only one pick per user and per mirror slot (`is_mirror_pick`).
- If a driver becomes unavailable while submitting (due to concurrent action), API returns conflict (`Driver no longer available`).
- If a pick edit arrives after the active slot window closed, API returns conflict (`Your turn is no longer active`).

### Effects
- Inserts pick and advances `currentPickIndex`.
- Editing an active previous pick updates the existing pick in place and does not advance `currentPickIndex`.
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
- If that reopened pick would otherwise have too little time left:
  - a deadline-1 pick is protected and extended to deadline 2
  - the ban is rejected if even deadline 2 would still be too late
- While a protected re-pick is active, bans are disabled for that active slot.
- Notifies next player after state change.
- Draft detail (`GET /api/leagues/:leagueID/draft/:raceID`) exposes:
  - `bannedByUserIDsByPickIndex` (who executed each visible ban slot)
  - `bansUsedByUserID` / `bansUsedByTeamID` + `banLimitPerActor` (ban usage metadata for UI)

## Standings and scoring
- Only non-banned picks are counted.
- League scoring uses only the main-race points stored in `race_results.points`.
- Sprint points (`race_results.sprint_points`) are excluded from every league calculation, including player/team standings, pick history, autopicks, expected-point deviations, and playoff seeding.
- Sprint points are included only in the official F1 driver and constructor standings exposed by `/api/standings/f1/drivers` and `/api/standings/f1/teams`.
- Autopicks are worth 50% of the main-race driver points.
- V2 resolved picks are materialized with `is_autopick = false` at FP1 and score 100%.
- Standings are computed over completed races.
- For mirrored picks, position calculation considers mirror order.

## PickDriver V2
- Drafts from season 2 round 14 (Dutch GP 2026, production `race_id = 39`) use `gameplay_version = v2`; prior completed history remains legacy.
- V2 has no player turns. Every league member maintains a private reusable ordered preference list; the resolver freezes one immutable snapshot per draft.
- Empty or partial lists are valid. If every listed driver is unavailable, the slot remains null and is a missed pick.
- With bans disabled, snapshot and publication happen at FP1. With bans enabled, they happen 24 hours before FP1 and bans remain open until FP1.
- Only resolved slot assignments are public. Other players' complete preference snapshots are never returned.
- A ban removes the selected driver from the target player's effective list and atomically recalculates that slot and every later slot.
- A player cannot ban themself or a teammate. Each target may be banned at most once per race.
- Ban budgets cover the whole league season: 2 per user without teams, or 3 shared by a team.
- Playoff ordering is finalized before the V2 snapshot is captured and resolved.

## Race-scoped driver substitutions
- Temporary substitutions do not rewrite a driver's season-level default team.
- Internal operations configure the complete substitution chain and effective roster for one race.
- Reconciliation always uses the immutable V2 preference snapshot for that draft, never the player's current reusable list.
- For a chain `A -> B -> C`, `A` maps to `B`. Driver `B` maps to `C` only when `A` appeared before `B` in that player's frozen list; otherwise `B` remains `B`.
- Effective drivers remain unique within a draft. If an effective driver is already held by an earlier slot, resolution advances to the next transformed preference using normal draft-order priority.
- `driver_id` remains the effective scoring driver. `original_driver_id` records the substituted preference for audit/history.
- Resolved and finalized V2 drafts can be reconciled transactionally after a late announcement. Repeated application of the same configuration is idempotent.
- Bans are not reopened. A candidate is excluded when either its original or effective driver was banned for that target.
- When a race roster exists, result publication rejects withdrawn/reserve drivers and driver/team mismatches.
- Legacy drafts are not automatically reinterpreted because they do not have immutable V2 preference snapshots.

## Draft-related notifications
- Starting draft notifies first user in order.
- Completing a pick notifies next user.
- Publishing results creates race-linked notifications.
