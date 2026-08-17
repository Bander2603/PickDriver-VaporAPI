import Fluent
import SQLKit
import Vapor

enum RaceCancellationService {
    private struct AffectedLeagueRow: Decodable {
        let league_id: Int
    }

    private struct CancelledDraftRow: Decodable {
        let draft_id: Int
        let pick_count: Int
    }

    private struct LeagueMemberOrderRow: Decodable {
        let user_id: Int
    }

    private struct LeagueDraftRow: Decodable {
        let draft_id: Int
        let race_id: Int
        let mirror_picks: Bool
        let race_status: String
    }

    private static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This operation requires an SQLDatabase (Postgres).")
        }
        return sql
    }

    @discardableResult
    static func invalidateCancelledDraftIfNeeded(
        raceID: Int,
        on db: any Database
    ) async throws -> Bool {
        try await invalidateCancelledDrafts(on: db, raceID: raceID) > 0
    }

    @discardableResult
    static func invalidateCancelledDrafts(
        on db: any Database,
        raceID: Int? = nil
    ) async throws -> Int {
        let sql = try sql(db)
        let affectedLeagueIDs = try await sql.raw(SQLQueryString("""
            SELECT DISTINCT rd.league_id AS league_id
            FROM race_drafts rd
            JOIN races r ON r.id = rd.race_id
            WHERE r.status = \(bind: Race.Status.cancelled.rawValue)
              AND (\(bind: raceID) IS NULL OR rd.race_id = \(bind: raceID))
        """)).all(decoding: AffectedLeagueRow.self).map(\.league_id)

        let cancelledDrafts = try await sql.raw(SQLQueryString("""
            SELECT
                rd.id AS draft_id,
                COALESCE(array_length(rd.pick_order, 1), 0) AS pick_count
            FROM race_drafts rd
            JOIN races r ON r.id = rd.race_id
            WHERE r.status = \(bind: Race.Status.cancelled.rawValue)
              AND (\(bind: raceID) IS NULL OR rd.race_id = \(bind: raceID))
              AND (
                    rd.status != \(bind: Race.Status.cancelled.rawValue)
                 OR rd.current_pick_index != COALESCE(array_length(rd.pick_order, 1), 0)
                 OR rd.protected_repick_user_id IS NOT NULL
                 OR rd.protected_repick_pick_index IS NOT NULL
                 OR rd.protected_repick_deadline IS NOT NULL
                 OR EXISTS (
                        SELECT 1
                        FROM player_picks pp
                        WHERE pp.draft_id = rd.id
                    )
                 OR EXISTS (
                        SELECT 1
                        FROM player_bans pb
                        WHERE pb.draft_id = rd.id
                    )
                 OR EXISTS (SELECT 1 FROM v2_draft_slots vs WHERE vs.draft_id = rd.id)
                 OR EXISTS (SELECT 1 FROM v2_draft_bans vb WHERE vb.draft_id = rd.id)
                 OR EXISTS (
                        SELECT 1
                        FROM draft_pick_preference_snapshots dps
                        WHERE dps.draft_id = rd.id
                    )
              )
        """)).all(decoding: CancelledDraftRow.self)

        guard !affectedLeagueIDs.isEmpty else {
            return 0
        }

        for draft in cancelledDrafts {
            try await sql.raw(SQLQueryString("""
                DELETE FROM player_picks
                WHERE draft_id = \(bind: draft.draft_id)
            """)).run()

            try await sql.raw(SQLQueryString("""
                DELETE FROM player_bans
                WHERE draft_id = \(bind: draft.draft_id)
            """)).run()

            try await sql.raw(SQLQueryString("""
                DELETE FROM v2_draft_bans WHERE draft_id = \(bind: draft.draft_id)
            """)).run()
            try await sql.raw(SQLQueryString("""
                DELETE FROM v2_draft_slots WHERE draft_id = \(bind: draft.draft_id)
            """)).run()
            try await sql.raw(SQLQueryString("""
                DELETE FROM draft_pick_preference_snapshots WHERE draft_id = \(bind: draft.draft_id)
            """)).run()

            try await sql.raw(SQLQueryString("""
                UPDATE race_drafts
                SET status = \(bind: Race.Status.cancelled.rawValue),
                    current_pick_index = \(bind: draft.pick_count),
                    protected_repick_user_id = NULL,
                    protected_repick_pick_index = NULL,
                    protected_repick_deadline = NULL,
                    resolution_state = CASE
                        WHEN gameplay_version = 'v2' THEN 'cancelled'
                        ELSE resolution_state
                    END,
                    updated_at = NOW()
                WHERE id = \(bind: draft.draft_id)
            """)).run()
        }

        for leagueID in affectedLeagueIDs {
            try await reconcileDraftOrdersForLeague(leagueID: leagueID, on: db)
        }

        return cancelledDrafts.count
    }

    private static func reconcileDraftOrdersForLeague(
        leagueID: Int,
        on database: any Database
    ) async throws {
        try await PlayoffService.synchronizeLeague(leagueID: leagueID, on: database)
        try await reconcileCancelledDraftHistory(leagueID: leagueID, on: database)
    }

    /// Cancelled races do not consume a rotation. Their stored order is kept
    /// as historical context, using the same order as the next playable race
    /// after any run of consecutive cancellations. This mirrors the original
    /// cancellation contract without mutating live drafts or final playoffs.
    private static func reconcileCancelledDraftHistory(
        leagueID: Int,
        on database: any Database
    ) async throws {
        let sql = try sql(database)
        let baseOrder = try await sql.raw("""
            SELECT user_id
            FROM league_members
            WHERE league_id = \(bind: leagueID)
              AND pick_order IS NOT NULL
            ORDER BY pick_order ASC
        """).all(decoding: LeagueMemberOrderRow.self).map(\.user_id)
        guard !baseOrder.isEmpty else {
            return
        }

        let draftRows = try await sql.raw("""
            SELECT
                rd.id AS draft_id,
                rd.race_id AS race_id,
                rd.mirror_picks AS mirror_picks,
                r.status AS race_status
            FROM race_drafts rd
            JOIN races r ON r.id = rd.race_id
            WHERE rd.league_id = \(bind: leagueID)
            ORDER BY r.round ASC, rd.id ASC
        """).all(decoding: LeagueDraftRow.self)

        var playableRaceCount = 0
        for draft in draftRows {
            let rotatedOrder = rotate(baseOrder, by: playableRaceCount)
            let expectedOrder = draft.mirror_picks
                ? rotatedOrder + rotatedOrder.reversed()
                : rotatedOrder

            if draft.race_status == Race.Status.cancelled.rawValue {
                let isFrozenPlayoff = try await PlayoffService.isFinalizedPlayoffRace(
                    leagueID: leagueID,
                    raceID: draft.race_id,
                    on: database
                )
                if !isFrozenPlayoff {
                    try await sql.raw("""
                        UPDATE race_drafts
                        SET pick_order = \(bind: expectedOrder),
                            status = \(bind: Race.Status.cancelled.rawValue),
                            current_pick_index = \(bind: expectedOrder.count),
                            protected_repick_user_id = NULL,
                            protected_repick_pick_index = NULL,
                            protected_repick_deadline = NULL,
                            updated_at = NOW()
                        WHERE id = \(bind: draft.draft_id)
                    """).run()
                }
                continue
            }

            playableRaceCount += 1
        }
    }

    private static func rotate(_ values: [Int], by offset: Int) -> [Int] {
        guard !values.isEmpty else {
            return []
        }
        let normalizedOffset = offset % values.count
        return Array(values.dropFirst(normalizedOffset) + values.prefix(normalizedOffset))
    }

}
