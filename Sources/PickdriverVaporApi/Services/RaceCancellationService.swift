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
        let pick_order: [Int]
        let current_pick_index: Int
        let mirror_picks: Bool
        let draft_status: String
        let race_status: String
        let has_picks: Bool
        let has_bans: Bool
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
                UPDATE race_drafts
                SET status = \(bind: Race.Status.cancelled.rawValue),
                    current_pick_index = \(bind: draft.pick_count),
                    protected_repick_user_id = NULL,
                    protected_repick_pick_index = NULL,
                    protected_repick_deadline = NULL,
                    updated_at = NOW()
                WHERE id = \(bind: draft.draft_id)
            """)).run()
        }

        for leagueID in affectedLeagueIDs {
            try await reconcileDraftOrdersForLeague(leagueID: leagueID, sql: sql)
        }

        return cancelledDrafts.count
    }

    private static func reconcileDraftOrdersForLeague(
        leagueID: Int,
        sql: any SQLDatabase
    ) async throws {
        let baseOrder = try await sql.raw(SQLQueryString("""
            SELECT user_id
            FROM league_members
            WHERE league_id = \(bind: leagueID)
              AND pick_order IS NOT NULL
            ORDER BY pick_order ASC
        """)).all(decoding: LeagueMemberOrderRow.self).map(\.user_id)

        guard !baseOrder.isEmpty else {
            return
        }

        let draftRows = try await sql.raw(SQLQueryString("""
            SELECT
                rd.id AS draft_id,
                rd.pick_order AS pick_order,
                rd.current_pick_index AS current_pick_index,
                rd.mirror_picks AS mirror_picks,
                rd.status AS draft_status,
                r.status AS race_status,
                EXISTS (
                    SELECT 1
                    FROM player_picks pp
                    WHERE pp.draft_id = rd.id
                ) AS has_picks,
                EXISTS (
                    SELECT 1
                    FROM player_bans pb
                    WHERE pb.draft_id = rd.id
                ) AS has_bans
            FROM race_drafts rd
            JOIN races r ON r.id = rd.race_id
            WHERE rd.league_id = \(bind: leagueID)
            ORDER BY r.round ASC, rd.id ASC
        """)).all(decoding: LeagueDraftRow.self)

        var playableRaceCount = 0

        for draft in draftRows {
            let rotatedOrder = rotate(baseOrder, by: playableRaceCount)
            let expectedOrder = draft.mirror_picks ? rotatedOrder + rotatedOrder.reversed() : rotatedOrder

            if draft.pick_order != expectedOrder {
                try await applyReconciledPickOrder(
                    draft: draft,
                    expectedOrder: expectedOrder,
                    sql: sql
                )
            }

            if draft.race_status != Race.Status.cancelled.rawValue {
                playableRaceCount += 1
            }
        }
    }

    private static func rotate(_ values: [Int], by offset: Int) -> [Int] {
        guard !values.isEmpty else {
            return []
        }

        let normalizedOffset = offset % values.count
        return Array(values.dropFirst(normalizedOffset) + values.prefix(normalizedOffset))
    }

    private static func applyReconciledPickOrder(
        draft: LeagueDraftRow,
        expectedOrder: [Int],
        sql: any SQLDatabase
    ) async throws {
        if draft.race_status == Race.Status.completed.rawValue {
            return
        }

        if draft.race_status == Race.Status.cancelled.rawValue {
            try await sql.raw(SQLQueryString("""
                UPDATE race_drafts
                SET pick_order = \(bind: expectedOrder),
                    status = \(bind: Race.Status.cancelled.rawValue),
                    current_pick_index = \(bind: expectedOrder.count),
                    protected_repick_user_id = NULL,
                    protected_repick_pick_index = NULL,
                    protected_repick_deadline = NULL,
                    updated_at = NOW()
                WHERE id = \(bind: draft.draft_id)
            """)).run()
            return
        }

        if draft.has_picks || draft.has_bans || draft.current_pick_index != 0 || draft.draft_status != "pending" {
            try await sql.raw(SQLQueryString("""
                DELETE FROM player_picks
                WHERE draft_id = \(bind: draft.draft_id)
            """)).run()

            try await sql.raw(SQLQueryString("""
                DELETE FROM player_bans
                WHERE draft_id = \(bind: draft.draft_id)
            """)).run()
        }

        try await sql.raw(SQLQueryString("""
            UPDATE race_drafts
            SET pick_order = \(bind: expectedOrder),
                status = \(bind: "pending"),
                current_pick_index = 0,
                protected_repick_user_id = NULL,
                protected_repick_pick_index = NULL,
                protected_repick_deadline = NULL,
                updated_at = NOW()
            WHERE id = \(bind: draft.draft_id)
        """)).run()
    }
}
