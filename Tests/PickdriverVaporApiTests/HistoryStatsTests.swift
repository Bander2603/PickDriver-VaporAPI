//
//  HistoryStatsTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class HistoryStatsTests: XCTestCase {

    // MARK: - Payloads

    private struct CreateLeaguePayload: Content {
        let name: String
        let maxPlayers: Int
        let teamsEnabled: Bool
        let bansEnabled: Bool
        let mirrorEnabled: Bool
    }

    private struct JoinLeaguePayload: Content {
        let code: String
    }

    private struct PickPayload: Content {
        let driverID: Int
    }

    private struct PickHistoryDTO: Content {
        let race_name: String
        let round: Int
        let pick_position: Int
        let driver_name: String
        let points: Double
        let expected_points: Double?
        let deviation: Double?
    }

    // MARK: - Helpers (API)

    private func createLeague(
        app: Application,
        token: String,
        name: String,
        maxPlayers: Int,
        teamsEnabled: Bool,
        bansEnabled: Bool = false,
        mirrorEnabled: Bool = false
    ) async throws -> League.Public {
        var created: League.Public?

        try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateLeaguePayload(
                name: name,
                maxPlayers: maxPlayers,
                teamsEnabled: teamsEnabled,
                bansEnabled: bansEnabled,
                mirrorEnabled: mirrorEnabled
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            created = try res.content.decode(League.Public.self)
        })

        return try XCTUnwrap(created)
    }

    private func joinLeague(app: Application, token: String, code: String) async throws {
        try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(JoinLeaguePayload(code: code))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func startDraft(app: Application, token: String, leagueID: Int) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/start-draft", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func getPickOrderFromDB(
        app: Application,
        leagueID: Int,
        raceID: Int
    ) async throws -> [Int] {
        let sql = try sql(app)
        struct Row: Decodable { let pick_order: [Int] }

        let row = try await sql.raw("""
            SELECT pick_order
            FROM race_drafts
            WHERE league_id = \(bind: leagueID) AND race_id = \(bind: raceID)
            LIMIT 1
        """).first(decoding: Row.self)

        let r = try XCTUnwrap(row, "race_drafts row not found for league \(leagueID), race \(raceID)")
        return r.pick_order
    }

    private func makePick(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int,
        driverID: Int
    ) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/pick", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PickPayload(driverID: driverID))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func fetchPickHistory(
        app: Application,
        token: String,
        leagueID: Int,
        userID: Int
    ) async throws -> [PickHistoryDTO] {
        var history: [PickHistoryDTO] = []

        try await app.test(.GET, "/api/players/standings/picks?league_id=\(leagueID)&user_id=\(userID)", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            history = try res.content.decode([PickHistoryDTO].self)
        })

        return history
    }

    private func makePicksForOrder(
        app: Application,
        leagueID: Int,
        raceID: Int,
        pickOrder: [Int],
        tokenByUserID: [Int: String],
        driverByUserID: [Int: Int]
    ) async throws {
        for userID in pickOrder {
            let token = try XCTUnwrap(tokenByUserID[userID], "Missing token for user \(userID)")
            let driverID = try XCTUnwrap(driverByUserID[userID], "Missing driver for user \(userID)")
            try await makePick(app: app, token: token, leagueID: leagueID, raceID: raceID, driverID: driverID)
        }
    }

    func testPickHistoryRequiresLeagueMembership_andTargetMember() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let creator = try await TestAuth.register(app: app)
            let outsider = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "League History Access",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)
            let creatorID = try XCTUnwrap(creator.publicUser.id)
            let outsiderID = try XCTUnwrap(outsider.publicUser.id)

            // Non-member cannot access pick history.
            try await app.test(.GET, "/api/players/standings/picks?league_id=\(leagueID)&user_id=\(creatorID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: outsider.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })

            // Member cannot request history for a user outside the league.
            try await app.test(.GET, "/api/players/standings/picks?league_id=\(leagueID)&user_id=\(outsiderID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })
        }
    }

    // MARK: - Helpers (DB)

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
    }

    private func insertRaceResult(
        app: Application,
        raceID: Int,
        driverID: Int,
        points: Int,
        f1TeamID: Int
    ) async throws {
        let sql = try sql(app)
        try await sql.raw("""
            INSERT INTO race_results (race_id, driver_id, points, f1_team_id)
            VALUES (\(bind: raceID), \(bind: driverID), \(bind: points), \(bind: f1TeamID))
        """).run()
    }

    private func markRaceCompleted(app: Application, raceID: Int) async throws {
        let sql = try sql(app)
        try await sql.raw("UPDATE races SET completed = true WHERE id = \(bind: raceID)").run()
    }

    // MARK: - Tests

    func testPickHistoryShowsDeviationAndMissedPickOrderedByRound() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "History Team", color: "#555555")

            let driver1 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Alpha",
                lastName: "One",
                driverNumber: 11,
                driverCode: "A01"
            )
            let driver2 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Beta",
                lastName: "Two",
                driverNumber: 22,
                driverCode: "B02"
            )
            let driver3 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Gamma",
                lastName: "Three",
                driverNumber: 33,
                driverCode: "G03"
            )

            let now = Date()
            let race1 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "History 1",
                completed: false,
                fp1Time: now.addingTimeInterval(40 * 3600),
                raceTime: now.addingTimeInterval(50 * 3600)
            )
            let race2 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 2,
                name: "History 2",
                completed: false,
                fp1Time: now.addingTimeInterval(3600),
                raceTime: now.addingTimeInterval(60 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "History League",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)
            let u1ID = try XCTUnwrap(u1.publicUser.id)
            let u2ID = try XCTUnwrap(u2.publicUser.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let pickOrderRace1 = try await getPickOrderFromDB(
                app: app,
                leagueID: leagueID,
                raceID: try race1.requireID()
            )
            let pickOrderRace2 = try await getPickOrderFromDB(
                app: app,
                leagueID: leagueID,
                raceID: try race2.requireID()
            )

            let tokenByUserID = [u1ID: u1.token, u2ID: u2.token]

            let driverByUserRace1 = [
                pickOrderRace1[0]: try driver1.requireID(),
                pickOrderRace1[1]: try driver2.requireID()
            ]
            try await makePicksForOrder(
                app: app,
                leagueID: leagueID,
                raceID: try race1.requireID(),
                pickOrder: pickOrderRace1,
                tokenByUserID: tokenByUserID,
                driverByUserID: driverByUserRace1
            )

            let missedUserID = pickOrderRace2[0]
            let pickerID = pickOrderRace2[1]
            let pickerToken = try XCTUnwrap(tokenByUserID[pickerID])

            try await makePick(
                app: app,
                token: pickerToken,
                leagueID: leagueID,
                raceID: try race2.requireID(),
                driverID: try driver3.requireID()
            )

            try await insertRaceResult(
                app: app,
                raceID: try race1.requireID(),
                driverID: try driver1.requireID(),
                points: 25,
                f1TeamID: f1Team.id
            )
            try await insertRaceResult(
                app: app,
                raceID: try race1.requireID(),
                driverID: try driver2.requireID(),
                points: 18,
                f1TeamID: f1Team.id
            )
            try await insertRaceResult(
                app: app,
                raceID: try race2.requireID(),
                driverID: try driver3.requireID(),
                points: 10,
                f1TeamID: f1Team.id
            )

            try await markRaceCompleted(app: app, raceID: try race1.requireID())
            try await markRaceCompleted(app: app, raceID: try race2.requireID())

            let history = try await fetchPickHistory(
                app: app,
                token: try XCTUnwrap(tokenByUserID[missedUserID]),
                leagueID: leagueID,
                userID: missedUserID
            )
            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(history.map { $0.round }, [1, 2])

            let expectedPointsByPick = [1: 25.0, 2: 18.0, 3: 15.0, 4: 12.0, 5: 10.0, 6: 8.0, 7: 6.0, 8: 4.0, 9: 2.0, 10: 1.0]
            for entry in history {
                let expected = try XCTUnwrap(entry.expected_points, "Expected points missing")
                XCTAssertEqual(expected, expectedPointsByPick[entry.pick_position])
                XCTAssertEqual(entry.deviation, entry.points - expected)
            }

            let driverNamesByID = [
                try driver1.requireID(): "Alpha One",
                try driver2.requireID(): "Beta Two",
                try driver3.requireID(): "Gamma Three"
            ]
            let pointsByDriverID = [
                try driver1.requireID(): 25.0,
                try driver2.requireID(): 18.0,
                try driver3.requireID(): 10.0
            ]

            let race1DriverForMissed = try XCTUnwrap(driverByUserRace1[missedUserID])
            XCTAssertEqual(history[0].driver_name, driverNamesByID[race1DriverForMissed])
            XCTAssertEqual(history[0].points, pointsByDriverID[race1DriverForMissed])
            XCTAssertEqual(history[0].pick_position, pickOrderRace1.firstIndex(of: missedUserID)! + 1)

            XCTAssertEqual(history[1].driver_name, "Missed Pick")
            XCTAssertEqual(history[1].points, 0.0)
            XCTAssertEqual(history[1].pick_position, pickOrderRace2.firstIndex(of: missedUserID)! + 1)
        }
    }
}
