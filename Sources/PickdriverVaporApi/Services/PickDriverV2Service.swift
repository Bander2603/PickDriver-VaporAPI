import Fluent
import SQLKit
import Vapor

enum PickDriverV2Service {
    struct BanResult: Content {
        let draftID: Int
        let targetUserID: Int
        let bannedDriverID: Int
        let targetPickIndex: Int
        let resolutionRevision: Int
    }

    private struct DueDraftRow: Decodable {
        let draft_id: Int
    }

    private struct LockedDraftRow: Decodable {
        let draft_id: Int
        let league_id: Int
        let race_id: Int
        let pick_order: [Int]
        let mirror_picks: Bool
        let resolution_state: String
        let resolution_revision: Int
        let bans_enabled: Bool
        let fp1_time: Date
        let race_completed: Bool
        let race_status: String
    }

    private struct SnapshotRow: Decodable {
        let user_id: Int
        let driver_order: [Int]
    }

    private struct BanRow: Decodable {
        let target_user_id: Int
        let target_driver_id: Int
    }

    static func submissionDeadline(fp1Time: Date, bansEnabled: Bool) -> Date {
        bansEnabled ? fp1Time.addingTimeInterval(-24 * 3600) : fp1Time
    }

    static func processDueDrafts(app: Application) async {
        guard let sql = app.db as? (any SQLDatabase) else {
            app.logger.warning("PickDriverV2Service: SQLDatabase required")
            return
        }

        do {
            let rows = try await sql.raw("""
                SELECT rd.id AS draft_id
                FROM race_drafts rd
                JOIN races r ON r.id = rd.race_id
                JOIN leagues l ON l.id = rd.league_id
                WHERE rd.gameplay_version = \(bind: DraftGameplayVersion.v2.rawValue)
                  AND rd.resolution_state IN (
                    \(bind: V2DraftResolutionState.collecting.rawValue),
                    \(bind: V2DraftResolutionState.resolved.rawValue)
                  )
                  AND r.completed = false
                  AND r.status != \(bind: Race.Status.cancelled.rawValue)
                  AND r.fp1_time IS NOT NULL
                  AND (
                    (rd.resolution_state = \(bind: V2DraftResolutionState.collecting.rawValue)
                      AND NOW() >= CASE WHEN l.bans_enabled THEN r.fp1_time - INTERVAL '24 hours' ELSE r.fp1_time END)
                    OR
                    (rd.resolution_state = \(bind: V2DraftResolutionState.resolved.rawValue)
                      AND NOW() >= r.fp1_time)
                  )
                ORDER BY r.fp1_time, rd.id
            """).all(decoding: DueDraftRow.self)

            for row in rows {
                do {
                    try await resolveOrFinalize(draftID: row.draft_id, now: Date(), on: app.db)
                } catch {
                    app.logger.error("PickDriverV2Service: draft \(row.draft_id) failed: \(error)")
                }
            }
        } catch {
            app.logger.error("PickDriverV2Service: due-draft query failed: \(error)")
        }
    }

    static func resolveIfDue(draftID: Int, now: Date = Date(), on database: any Database) async throws {
        try await resolveOrFinalize(draftID: draftID, now: now, on: database)
    }

    /// Freezes every due V2 draft before a reusable preference is changed. This makes a
    /// post-deadline PUT apply to the next draft even if the periodic worker has not run yet.
    static func freezeDueDraftsBeforePreferenceUpdate(
        leagueID: Int,
        now: Date = Date(),
        on database: any Database
    ) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required for V2 preferences.")
        }
        let rows = try await sql.raw("""
            SELECT rd.id AS draft_id
            FROM race_drafts rd
            JOIN races r ON r.id = rd.race_id
            JOIN leagues l ON l.id = rd.league_id
            WHERE rd.league_id = \(bind: leagueID)
              AND rd.gameplay_version = \(bind: DraftGameplayVersion.v2.rawValue)
              AND rd.resolution_state = \(bind: V2DraftResolutionState.collecting.rawValue)
              AND r.fp1_time IS NOT NULL
              AND \(bind: now) >= CASE
                    WHEN l.bans_enabled THEN r.fp1_time - INTERVAL '24 hours'
                    ELSE r.fp1_time
                  END
            ORDER BY r.fp1_time, rd.id
        """).all(decoding: DueDraftRow.self)
        for row in rows {
            try await resolveOrFinalize(draftID: row.draft_id, now: now, on: database)
        }
    }

    static func ban(
        leagueID: Int,
        raceID: Int,
        actorUserID: Int,
        targetUserID: Int,
        driverID: Int,
        now: Date = Date(),
        on database: any Database
    ) async throws -> BanResult {
        try await database.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for V2 bans.")
            }

            struct BanDraftRow: Decodable {
                let draft_id: Int
                let pick_order: [Int]
                let mirror_picks: Bool
                let resolution_state: String
                let resolution_revision: Int
                let teams_enabled: Bool
                let bans_enabled: Bool
                let season_id: Int
                let fp1_time: Date
            }
            struct SlotRow: Decodable {
                let pick_index: Int
            }
            struct TeamRow: Decodable {
                let user_id: Int
                let team_id: Int
            }
            struct CountRow: Decodable {
                let count: Int
            }

            guard let draft = try await sql.raw("""
                SELECT rd.id AS draft_id, rd.pick_order, rd.mirror_picks,
                       rd.resolution_state, rd.resolution_revision,
                       l.teams_enabled, l.bans_enabled, r.season_id, r.fp1_time
                FROM race_drafts rd
                JOIN leagues l ON l.id = rd.league_id
                JOIN races r ON r.id = rd.race_id
                WHERE rd.league_id = \(bind: leagueID)
                  AND rd.race_id = \(bind: raceID)
                  AND rd.gameplay_version = \(bind: DraftGameplayVersion.v2.rawValue)
                  AND r.fp1_time IS NOT NULL
                FOR UPDATE OF rd
            """).first(decoding: BanDraftRow.self) else {
                throw Abort(.notFound, reason: "PickDriver V2 draft not found.")
            }

            guard draft.bans_enabled else {
                throw Abort(.badRequest, reason: "Bans are disabled in this league.")
            }
            guard draft.resolution_state == V2DraftResolutionState.resolved.rawValue else {
                throw Abort(.conflict, reason: "The V2 draft must be resolved before bans can be submitted.")
            }
            let opensAt = draft.fp1_time.addingTimeInterval(-24 * 3600)
            guard now >= opensAt, now < draft.fp1_time else {
                throw Abort(.badRequest, reason: "Bans are only available from 24 hours before FP1 until FP1.")
            }
            guard actorUserID != targetUserID else {
                throw Abort(.forbidden, reason: "You cannot ban your own pick.")
            }
            guard draft.pick_order.contains(actorUserID) else {
                throw Abort(.forbidden, reason: "Only players in this draft can submit a ban.")
            }

            guard let targetSlot = try await sql.raw("""
                SELECT pick_index
                FROM v2_draft_slots
                WHERE draft_id = \(bind: draft.draft_id)
                  AND user_id = \(bind: targetUserID)
                  AND driver_id = \(bind: driverID)
                ORDER BY pick_index
                LIMIT 1
            """).first(decoding: SlotRow.self) else {
                throw Abort(.notFound, reason: "The published pick to ban was not found.")
            }

            let teamRows = try await sql.raw("""
                SELECT tm.user_id, tm.team_id
                FROM team_members tm
                JOIN league_teams lt ON lt.id = tm.team_id
                WHERE lt.league_id = \(bind: leagueID)
                  AND tm.user_id IN (\(bind: actorUserID), \(bind: targetUserID))
            """).all(decoding: TeamRow.self)
            let teamByUser = Dictionary(uniqueKeysWithValues: teamRows.map { ($0.user_id, $0.team_id) })

            let actorTeamID: Int?
            if draft.teams_enabled {
                guard let resolvedActorTeamID = teamByUser[actorUserID],
                      let targetTeamID = teamByUser[targetUserID] else {
                    throw Abort(.conflict, reason: "Both players must have a team before using V2 bans.")
                }
                guard resolvedActorTeamID != targetTeamID else {
                    throw Abort(.forbidden, reason: "You cannot ban a teammate.")
                }
                actorTeamID = resolvedActorTeamID
            } else {
                actorTeamID = nil
            }

            let seasonUsage: Int
            let seasonLimit: Int
            if let actorTeamID {
                seasonUsage = try await sql.raw("""
                    SELECT COUNT(*)::integer AS count
                    FROM v2_draft_bans vb
                    JOIN race_drafts rd ON rd.id = vb.draft_id
                    JOIN races r ON r.id = rd.race_id
                    WHERE rd.league_id = \(bind: leagueID)
                      AND r.season_id = \(bind: draft.season_id)
                      AND vb.actor_team_id = \(bind: actorTeamID)
                """).first(decoding: CountRow.self)?.count ?? 0
                seasonLimit = 3
            } else {
                seasonUsage = try await sql.raw("""
                    SELECT COUNT(*)::integer AS count
                    FROM v2_draft_bans vb
                    JOIN race_drafts rd ON rd.id = vb.draft_id
                    JOIN races r ON r.id = rd.race_id
                    WHERE rd.league_id = \(bind: leagueID)
                      AND r.season_id = \(bind: draft.season_id)
                      AND vb.actor_user_id = \(bind: actorUserID)
                      AND vb.actor_team_id IS NULL
                """).first(decoding: CountRow.self)?.count ?? 0
                seasonLimit = 2
            }
            guard seasonUsage < seasonLimit else {
                throw Abort(.badRequest, reason: "No bans remaining for this league season.")
            }

            let revision = draft.resolution_revision + 1
            do {
                try await sql.raw("""
                    INSERT INTO v2_draft_bans (
                        draft_id, actor_user_id, actor_team_id, target_user_id,
                        target_driver_id, target_pick_index, resolution_revision, created_at
                    ) VALUES (
                        \(bind: draft.draft_id), \(bind: actorUserID), \(bind: actorTeamID),
                        \(bind: targetUserID), \(bind: driverID), \(bind: targetSlot.pick_index),
                        \(bind: revision), NOW()
                    )
                """).run()
            } catch {
                throw Abort(.conflict, reason: "This team/player already used its ban, or the target was already banned in this race.")
            }

            try await recalculateSlots(
                draftID: draft.draft_id,
                pickOrder: draft.pick_order,
                mirrorPicks: draft.mirror_picks,
                fromPickIndex: targetSlot.pick_index,
                revision: revision,
                sql: sql
            )
            try await sql.raw("""
                UPDATE race_drafts
                SET resolution_revision = \(bind: revision), updated_at = NOW()
                WHERE id = \(bind: draft.draft_id)
            """).run()

            return BanResult(
                draftID: draft.draft_id,
                targetUserID: targetUserID,
                bannedDriverID: driverID,
                targetPickIndex: targetSlot.pick_index,
                resolutionRevision: revision
            )
        }
    }

    private static func resolveOrFinalize(draftID: Int, now: Date, on database: any Database) async throws {
        try await database.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for V2 resolution.")
            }

            guard let draft = try await sql.raw("""
                SELECT
                    rd.id AS draft_id,
                    rd.league_id AS league_id,
                    rd.race_id AS race_id,
                    rd.pick_order AS pick_order,
                    rd.mirror_picks AS mirror_picks,
                    rd.resolution_state AS resolution_state,
                    rd.resolution_revision AS resolution_revision,
                    l.bans_enabled AS bans_enabled,
                    r.fp1_time AS fp1_time,
                    r.completed AS race_completed,
                    r.status AS race_status
                FROM race_drafts rd
                JOIN leagues l ON l.id = rd.league_id
                JOIN races r ON r.id = rd.race_id
                WHERE rd.id = \(bind: draftID)
                  AND rd.gameplay_version = \(bind: DraftGameplayVersion.v2.rawValue)
                  AND r.fp1_time IS NOT NULL
                FOR UPDATE OF rd
            """).first(decoding: LockedDraftRow.self) else {
                return
            }

            if draft.race_completed || draft.race_status == Race.Status.cancelled.rawValue {
                try await sql.raw("""
                    UPDATE race_drafts
                    SET resolution_state = \(bind: V2DraftResolutionState.cancelled.rawValue)
                    WHERE id = \(bind: draftID)
                      AND resolution_state != \(bind: V2DraftResolutionState.finalized.rawValue)
                """).run()
                return
            }

            let deadline = submissionDeadline(fp1Time: draft.fp1_time, bansEnabled: draft.bans_enabled)
            if draft.resolution_state == V2DraftResolutionState.collecting.rawValue, now >= deadline {
                guard !draft.pick_order.isEmpty else {
                    return
                }
                try await captureSnapshots(
                    draftID: draftID,
                    leagueID: draft.league_id,
                    pickOrder: draft.pick_order,
                    sql: sql
                )
                try await recalculateSlots(
                    draftID: draftID,
                    pickOrder: draft.pick_order,
                    mirrorPicks: draft.mirror_picks,
                    fromPickIndex: 0,
                    revision: draft.resolution_revision + 1,
                    sql: sql
                )
                try await sql.raw("""
                    UPDATE race_drafts
                    SET resolution_state = \(bind: V2DraftResolutionState.resolved.rawValue),
                        resolution_revision = \(bind: draft.resolution_revision + 1),
                        resolved_at = COALESCE(resolved_at, \(bind: now)),
                        current_pick_index = cardinality(pick_order),
                        updated_at = NOW()
                    WHERE id = \(bind: draftID)
                """).run()
            }

            if now >= draft.fp1_time {
                try await materializeFinalPicks(draftID: draftID, sql: sql)
                try await sql.raw("""
                    UPDATE race_drafts
                    SET resolution_state = \(bind: V2DraftResolutionState.finalized.rawValue),
                        current_pick_index = cardinality(pick_order),
                        updated_at = NOW()
                    WHERE id = \(bind: draftID)
                      AND resolution_state IN (
                        \(bind: V2DraftResolutionState.resolved.rawValue),
                        \(bind: V2DraftResolutionState.finalized.rawValue)
                      )
                """).run()
            }
        }
    }

    static func recalculateSlots(
        draftID: Int,
        pickOrder: [Int],
        mirrorPicks: Bool,
        fromPickIndex: Int,
        revision: Int,
        sql: any SQLDatabase
    ) async throws {
        let snapshots = try await sql.raw("""
            SELECT user_id, driver_order
            FROM draft_pick_preference_snapshots
            WHERE draft_id = \(bind: draftID)
        """).all(decoding: SnapshotRow.self)
        let preferencesByUser = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.user_id, $0.driver_order) })

        let bans = try await sql.raw("""
            SELECT target_user_id, target_driver_id
            FROM v2_draft_bans
            WHERE draft_id = \(bind: draftID)
        """).all(decoding: BanRow.self)
        let bannedDriversByUser = Dictionary(grouping: bans, by: \.target_user_id)
            .mapValues { Set($0.map(\.target_driver_id)) }

        let prefixDrivers = try await sql.raw("""
            SELECT driver_id
            FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
              AND pick_index < \(bind: fromPickIndex)
              AND driver_id IS NOT NULL
            ORDER BY pick_index
        """).all(decoding: [String: Int].self)
        var unavailable = Set(prefixDrivers.compactMap { $0["driver_id"] })

        try await sql.raw("""
            DELETE FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
              AND pick_index >= \(bind: fromPickIndex)
        """).run()

        var seenUsers = Set(pickOrder.prefix(fromPickIndex))
        for pickIndex in fromPickIndex..<pickOrder.count {
            let userID = pickOrder[pickIndex]
            let isMirrorPick = mirrorPicks && seenUsers.contains(userID)
            let bannedDrivers = bannedDriversByUser[userID] ?? []
            let driverID = preferencesByUser[userID]?.first {
                !unavailable.contains($0) && !bannedDrivers.contains($0)
            }

            try await sql.raw("""
                INSERT INTO v2_draft_slots (
                    draft_id, pick_index, user_id, driver_id, is_mirror_pick,
                    resolution_revision, updated_at
                ) VALUES (
                    \(bind: draftID), \(bind: pickIndex), \(bind: userID),
                    \(bind: driverID), \(bind: isMirrorPick), \(bind: revision), NOW()
                )
            """).run()

            if let driverID {
                unavailable.insert(driverID)
            }
            seenUsers.insert(userID)
        }
    }

    private static func captureSnapshots(
        draftID: Int,
        leagueID: Int,
        pickOrder: [Int],
        sql: any SQLDatabase
    ) async throws {
        for userID in Set(pickOrder) {
            try await sql.raw("""
                INSERT INTO draft_pick_preference_snapshots (draft_id, user_id, driver_order, captured_at)
                SELECT \(bind: draftID), \(bind: userID), COALESCE(ppp.driver_order, '{}'::integer[]), NOW()
                FROM (SELECT 1) seed
                LEFT JOIN player_pick_preferences ppp
                  ON ppp.league_id = \(bind: leagueID)
                 AND ppp.user_id = \(bind: userID)
                ON CONFLICT (draft_id, user_id) DO NOTHING
            """).run()
        }
    }

    private static func materializeFinalPicks(draftID: Int, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO player_picks (
                draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick, picked_at
            )
            SELECT draft_id, user_id, driver_id, false, is_mirror_pick, false, NOW()
            FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
              AND driver_id IS NOT NULL
            ORDER BY pick_index
            ON CONFLICT DO NOTHING
        """).run()
    }
}
