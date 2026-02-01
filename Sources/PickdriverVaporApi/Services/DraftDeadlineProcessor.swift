//
//  DraftDeadlineProcessor.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 01.02.26.
//

import Vapor
import SQLKit

struct DraftDeadlineProcessor {
    private struct DraftRow: Decodable {
        let draft_id: Int
        let league_id: Int
        let race_id: Int
        let pick_order: [Int]
        let current_pick_index: Int
        let mirror_picks: Bool
        let fp1_time: Date
        let race_time: Date?
    }

    static func processExpiredDrafts(app: Application) async {
        guard let sql = app.db as? (any SQLDatabase) else {
            app.logger.warning("DraftDeadlineProcessor: SQLDatabase required to process deadlines")
            return
        }

        let now = Date()

        do {
            let rows = try await sql.raw("""
                SELECT
                    rd.id AS draft_id,
                    rd.league_id AS league_id,
                    rd.race_id AS race_id,
                    rd.pick_order AS pick_order,
                    rd.current_pick_index AS current_pick_index,
                    rd.mirror_picks AS mirror_picks,
                    r.fp1_time AS fp1_time,
                    r.race_time AS race_time
                FROM race_drafts rd
                JOIN races r ON r.id = rd.race_id
                WHERE r.completed = false
                  AND r.fp1_time IS NOT NULL
                  AND rd.current_pick_index < COALESCE(array_length(rd.pick_order, 1), 0)
            """).all(decoding: DraftRow.self)

            for row in rows {
                if let raceTime = row.race_time, raceTime < now {
                    continue
                }

                let firstHalfDeadline = Calendar.current.date(byAdding: .hour, value: -36, to: row.fp1_time)!
                let deadlines = DraftDeadline(
                    raceID: row.race_id,
                    leagueID: row.league_id,
                    firstHalfDeadline: firstHalfDeadline,
                    secondHalfDeadline: row.fp1_time
                )

                do {
                    _ = try await advanceExpiredTurns(
                        draftID: row.draft_id,
                        leagueID: row.league_id,
                        pickOrder: row.pick_order,
                        currentPickIndex: row.current_pick_index,
                        mirrorPicks: row.mirror_picks,
                        deadlines: deadlines,
                        now: now,
                        sql: sql
                    )
                } catch {
                    app.logger.error("DraftDeadlineProcessor: failed for draft \(row.draft_id): \(error)")
                }
            }
        } catch {
            app.logger.error("DraftDeadlineProcessor: query failed: \(error)")
        }
    }

    static func advanceExpiredTurns(
        draftID: Int,
        leagueID: Int,
        pickOrder: [Int],
        currentPickIndex: Int,
        mirrorPicks: Bool,
        deadlines: DraftDeadline,
        now: Date,
        sql: any SQLDatabase
    ) async throws -> Int {
        guard !pickOrder.isEmpty else { return currentPickIndex }

        var index = currentPickIndex
        var advanced = false
        let firstHalfCount = (pickOrder.count + 1) / 2

        while index < pickOrder.count {
            let deadline = index < firstHalfCount ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline
            if now <= deadline { break }
            let currentTurnUserID = pickOrder[index]
            let isMirrorPick = mirrorPicks && pickOrder.prefix(index).contains(currentTurnUserID)
            _ = try await attemptAutopick(
                draftID: draftID,
                leagueID: leagueID,
                userID: currentTurnUserID,
                isMirrorPick: isMirrorPick,
                sql: sql
            )
            index += 1
            advanced = true
        }

        if advanced {
            let row = try await sql.raw("""
                UPDATE race_drafts
                SET current_pick_index = GREATEST(current_pick_index, \(bind: index))
                WHERE id = \(bind: draftID)
                RETURNING current_pick_index
            """).first(decoding: [String: Int].self)
            return row?["current_pick_index"] ?? index
        }

        return currentPickIndex
    }

    private static func attemptAutopick(
        draftID: Int,
        leagueID: Int,
        userID: Int,
        isMirrorPick: Bool,
        sql: any SQLDatabase
    ) async throws -> Int? {
        let existingPick = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
              AND is_banned = false
              AND is_mirror_pick = \(bind: isMirrorPick)
            LIMIT 1
        """).first()

        guard existingPick == nil else { return nil }

        let autopickRow = try await sql.raw("""
            SELECT driver_order FROM player_autopicks
            WHERE league_id = \(bind: leagueID)
              AND user_id = \(bind: userID)
            LIMIT 1
        """).first(decoding: [String: [Int]].self)

        guard let driverOrder = autopickRow?["driver_order"], !driverOrder.isEmpty else {
            return nil
        }

        let bannedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
              AND is_banned = true
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        let pickedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = false
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        let availableDrivers = driverOrder.filter { !bannedDrivers.contains($0) && !pickedDrivers.contains($0) }

        for driverID in availableDrivers {
            let inserted = try await sql.raw("""
                INSERT INTO player_picks (draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick, picked_at)
                VALUES (\(bind: draftID), \(bind: userID), \(bind: driverID), false, \(bind: isMirrorPick), true, NOW())
                ON CONFLICT DO NOTHING
                RETURNING id
            """).first(decoding: [String: Int].self)

            if inserted != nil {
                return driverID
            }

            let pickExists = try await sql.raw("""
                SELECT 1 FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND user_id = \(bind: userID)
                  AND is_banned = false
                  AND is_mirror_pick = \(bind: isMirrorPick)
                LIMIT 1
            """).first()

            if pickExists != nil {
                return nil
            }
        }

        return nil
    }
}
