//
//  RaceResultsTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class RaceResultsTests: XCTestCase {

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
        let points: Int
        let expected_points: Int?
        let deviation: Int?
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

    private func getPickOrder(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int
    ) async throws -> [Int] {
        var order: [Int] = []

        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/pick-order", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            order = try res.content.decode([Int].self)
        })

        return order
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

    // MARK: - Helpers (DB)

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
    }

    private func insertRaceResult(
        app: Application,
        raceID: Int,
        driverID: Int,
        points: Int,
        sprintPoints: Int? = nil,
        f1TeamID: Int
    ) async throws {
        let sql = try sql(app)
        try await sql.raw("""
            INSERT INTO race_results (race_id, driver_id, points, sprint_points, f1_team_id)
            VALUES (\(bind: raceID), \(bind: driverID), \(bind: points), \(bind: sprintPoints), \(bind: f1TeamID))
        """).run()
    }

    private func markRaceCompleted(app: Application, raceID: Int) async throws {
        let sql = try sql(app)
        try await sql.raw("UPDATE races SET completed = true WHERE id = \(bind: raceID)").run()
    }

    // MARK: - Tests

    func testDriverStandingsIncludeSprintPoints() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Points Team", color: "#333333")

            let driverA = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Sprint",
                lastName: "Boost",
                driverNumber: 7,
                driverCode: "SPR"
            )
            let driverB = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Main",
                lastName: "Only",
                driverNumber: 8,
                driverCode: "MAN"
            )

            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Sprint GP",
                completed: true,
                raceTime: Date().addingTimeInterval(-3600)
            )

            try await insertRaceResult(
                app: app,
                raceID: try race.requireID(),
                driverID: try driverA.requireID(),
                points: 18,
                sprintPoints: 6,
                f1TeamID: f1Team.id
            )
            try await insertRaceResult(
                app: app,
                raceID: try race.requireID(),
                driverID: try driverB.requireID(),
                points: 20,
                sprintPoints: 0,
                f1TeamID: f1Team.id
            )

            try await app.test(.GET, "/api/standings/f1/drivers", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let standings = try res.content.decode([DriverStanding].self)
                XCTAssertEqual(standings.count, 2)

                let byDriver = Dictionary(uniqueKeysWithValues: standings.map { ($0.driver_id, $0) })
                XCTAssertEqual(byDriver[try driverA.requireID()]?.points, 24)
                XCTAssertEqual(byDriver[try driverB.requireID()]?.points, 20)
                XCTAssertEqual(standings.first?.driver_id, try driverA.requireID())
            })
        }
    }

    func testPickHistoryUsesRaceResultsPoints() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "History Team", color: "#444444")

            let driverHigh = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Max",
                lastName: "Fast",
                driverNumber: 1,
                driverCode: "HIG"
            )
            let driverLow = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Low",
                lastName: "Score",
                driverNumber: 2,
                driverCode: "LOW"
            )

            let now = Date()
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "History GP",
                completed: false,
                fp1Time: now.addingTimeInterval(7 * 24 * 3600),
                raceTime: now.addingTimeInterval(9 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Results League",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)
            let u1ID = try XCTUnwrap(u1.publicUser.id)
            let u2ID = try XCTUnwrap(u2.publicUser.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let pickOrder = try await getPickOrder(
                app: app,
                token: u1.token,
                leagueID: leagueID,
                raceID: try race.requireID()
            )

            let tokenByUserID = [u1ID: u1.token, u2ID: u2.token]
            let driverByUserID = [
                u1ID: try driverHigh.requireID(),
                u2ID: try driverLow.requireID()
            ]

            try await makePicksForOrder(
                app: app,
                leagueID: leagueID,
                raceID: try race.requireID(),
                pickOrder: pickOrder,
                tokenByUserID: tokenByUserID,
                driverByUserID: driverByUserID
            )

            try await insertRaceResult(
                app: app,
                raceID: try race.requireID(),
                driverID: try driverHigh.requireID(),
                points: 25,
                f1TeamID: f1Team.id
            )
            try await markRaceCompleted(app: app, raceID: try race.requireID())

            let expectedPointsByPick = [1: 25, 2: 18, 3: 15, 4: 12, 5: 10, 6: 8, 7: 6, 8: 4, 9: 2, 10: 1]

            let historyU1 = try await fetchPickHistory(app: app, token: u1.token, leagueID: leagueID, userID: u1ID)
            XCTAssertEqual(historyU1.count, 1)
            XCTAssertEqual(historyU1.first?.driver_name, "Max Fast")
            XCTAssertEqual(historyU1.first?.points, 25)
            if let pickPosition = historyU1.first?.pick_position {
                XCTAssertEqual(historyU1.first?.expected_points, expectedPointsByPick[pickPosition])
            }

            let historyU2 = try await fetchPickHistory(app: app, token: u2.token, leagueID: leagueID, userID: u2ID)
            XCTAssertEqual(historyU2.count, 1)
            XCTAssertEqual(historyU2.first?.driver_name, "Low Score")
            XCTAssertEqual(historyU2.first?.points, 0)
            if let pickPosition = historyU2.first?.pick_position {
                XCTAssertEqual(historyU2.first?.expected_points, expectedPointsByPick[pickPosition])
            }
        }
    }
}
