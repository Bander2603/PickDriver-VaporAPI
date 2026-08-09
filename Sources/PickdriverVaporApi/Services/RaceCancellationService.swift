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
            try await reconcileDraftOrdersForLeague(leagueID: leagueID, on: db)
        }

        return cancelledDrafts.count
    }

    private static func reconcileDraftOrdersForLeague(
        leagueID: Int,
        on database: any Database
    ) async throws {
        try await PlayoffService.synchronizeLeague(leagueID: leagueID, on: database)
    }

}
