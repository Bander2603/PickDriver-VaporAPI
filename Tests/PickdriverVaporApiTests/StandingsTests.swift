//
//  StandingsTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class StandingsTests: XCTestCase {

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

    private struct CreateTeamPayload: Content {
        let leagueID: Int
        let name: String
        let userIDs: [Int]

        enum CodingKeys: String, CodingKey {
            case leagueID = "league_id"
            case name
            case userIDs = "user_ids"
        }
    }

    private struct PickPayload: Content {
        let driverID: Int
    }

    private struct PlayerStandingDTO: Content {
        let user_id: Int
        let username: String
        let total_points: Int
        let team_id: Int?
        let total_deviation: Int
    }

    private struct TeamStandingDTO: Content {
        let team_id: Int
        let name: String
        let total_points: Int
        let total_deviation: Int
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

    private func createTeam(
        app: Application,
        token: String,
        leagueID: Int,
        name: String,
        userIDs: [Int]
    ) async throws {
        try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateTeamPayload(leagueID: leagueID, name: name, userIDs: userIDs))
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

    private func fetchPlayerStandings(app: Application, token: String, leagueID: Int) async throws -> [PlayerStandingDTO] {
        var standings: [PlayerStandingDTO] = []

        try await app.test(.GET, "/api/players/standings/players?league_id=\(leagueID)", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            standings = try res.content.decode([PlayerStandingDTO].self)
        })

        return standings
    }

    private func fetchTeamStandings(app: Application, token: String, leagueID: Int) async throws -> [TeamStandingDTO] {
        var standings: [TeamStandingDTO] = []

        try await app.test(.GET, "/api/players/standings/teams?league_id=\(leagueID)", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            standings = try res.content.decode([TeamStandingDTO].self)
        })

        return standings
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

    func testStandingsRequireLeagueMembership() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let creator = try await TestAuth.register(app: app)
            let outsider = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "League Standings Access",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)

            try await app.test(.GET, "/api/players/standings/players?league_id=\(leagueID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: outsider.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })

            try await app.test(.GET, "/api/players/standings/teams?league_id=\(leagueID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: outsider.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })
        }
    }

    // MARK: - Helpers (DB)

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
    }

    private func insertRaceResults(
        app: Application,
        raceID: Int,
        f1TeamID: Int,
        results: [(driverID: Int, points: Int)]
    ) async throws {
        let sql = try sql(app)

        for result in results {
            try await sql.raw("""
                INSERT INTO race_results (race_id, driver_id, points, f1_team_id)
                VALUES (\(bind: raceID), \(bind: result.driverID), \(bind: result.points), \(bind: f1TeamID))
            """).run()
        }
    }

    private func markRaceCompleted(app: Application, raceID: Int) async throws {
        let sql = try sql(app)
        try await sql.raw("UPDATE races SET completed = true WHERE id = \(bind: raceID)").run()
    }

    // MARK: - Tests

    func testPlayerStandingsRecalculateAfterRaceResults() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Test Team", color: "#111111")

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
            let race1 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Race 1",
                completed: false,
                fp1Time: now.addingTimeInterval(7 * 24 * 3600),
                raceTime: now.addingTimeInterval(9 * 24 * 3600)
            )
            let race2 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 2,
                name: "Race 2",
                completed: false,
                fp1Time: now.addingTimeInterval(14 * 24 * 3600),
                raceTime: now.addingTimeInterval(16 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Standings League",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)
            let u1ID = try XCTUnwrap(u1.publicUser.id)
            let u2ID = try XCTUnwrap(u2.publicUser.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let pickOrderRace1 = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: try race1.requireID())
            let pickOrderRace2 = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: try race2.requireID())

            let tokenByUserID = [u1ID: u1.token, u2ID: u2.token]

            let race1Assignments = [
                u1ID: try driverHigh.requireID(),
                u2ID: try driverLow.requireID()
            ]
            try await makePicksForOrder(
                app: app,
                leagueID: leagueID,
                raceID: try race1.requireID(),
                pickOrder: pickOrderRace1,
                tokenByUserID: tokenByUserID,
                driverByUserID: race1Assignments
            )

            let race2Assignments = [
                u1ID: try driverLow.requireID(),
                u2ID: try driverHigh.requireID()
            ]
            try await makePicksForOrder(
                app: app,
                leagueID: leagueID,
                raceID: try race2.requireID(),
                pickOrder: pickOrderRace2,
                tokenByUserID: tokenByUserID,
                driverByUserID: race2Assignments
            )

            try await insertRaceResults(
                app: app,
                raceID: try race1.requireID(),
                f1TeamID: f1Team.id,
                results: [
                    (driverID: try driverHigh.requireID(), points: 25),
                    (driverID: try driverLow.requireID(), points: 18)
                ]
            )
            try await markRaceCompleted(app: app, raceID: try race1.requireID())

            let standingsAfterRace1 = try await fetchPlayerStandings(app: app, token: u1.token, leagueID: leagueID)
            XCTAssertEqual(standingsAfterRace1.count, 2)

            let byUserAfterRace1 = Dictionary(uniqueKeysWithValues: standingsAfterRace1.map { ($0.user_id, $0) })
            XCTAssertEqual(byUserAfterRace1[u1ID]?.total_points, 25)
            XCTAssertEqual(byUserAfterRace1[u2ID]?.total_points, 18)
            XCTAssertNil(byUserAfterRace1[u1ID]?.team_id)
            XCTAssertEqual(standingsAfterRace1.first?.user_id, u1ID)

            try await insertRaceResults(
                app: app,
                raceID: try race2.requireID(),
                f1TeamID: f1Team.id,
                results: [
                    (driverID: try driverHigh.requireID(), points: 25),
                    (driverID: try driverLow.requireID(), points: 0)
                ]
            )
            try await markRaceCompleted(app: app, raceID: try race2.requireID())

            let standingsAfterRace2 = try await fetchPlayerStandings(app: app, token: u1.token, leagueID: leagueID)
            XCTAssertEqual(standingsAfterRace2.count, 2)

            let byUserAfterRace2 = Dictionary(uniqueKeysWithValues: standingsAfterRace2.map { ($0.user_id, $0) })
            XCTAssertEqual(byUserAfterRace2[u1ID]?.total_points, 25)
            XCTAssertEqual(byUserAfterRace2[u2ID]?.total_points, 43)
            XCTAssertEqual(standingsAfterRace2.first?.user_id, u2ID)
        }
    }

    func testTeamStandingsAggregatesTeamPoints() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Team Points", color: "#222222")

            let driver1 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "A",
                lastName: "One",
                driverNumber: 11,
                driverCode: "A01"
            )
            let driver2 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "B",
                lastName: "Two",
                driverNumber: 22,
                driverCode: "B02"
            )
            let driver3 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "C",
                lastName: "Three",
                driverNumber: 33,
                driverCode: "C03"
            )
            let driver4 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "D",
                lastName: "Four",
                driverNumber: 44,
                driverCode: "D04"
            )

            let now = Date()
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Race Teams",
                completed: false,
                fp1Time: now.addingTimeInterval(7 * 24 * 3600),
                raceTime: now.addingTimeInterval(9 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)
            let u4 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Team Standings League",
                maxPlayers: 4,
                teamsEnabled: true
            )

            let leagueID = try XCTUnwrap(league.id)
            let u1ID = try XCTUnwrap(u1.publicUser.id)
            let u2ID = try XCTUnwrap(u2.publicUser.id)
            let u3ID = try XCTUnwrap(u3.publicUser.id)
            let u4ID = try XCTUnwrap(u4.publicUser.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await joinLeague(app: app, token: u3.token, code: league.code)
            try await joinLeague(app: app, token: u4.token, code: league.code)

            try await createTeam(app: app, token: u1.token, leagueID: leagueID, name: "Team A", userIDs: [u1ID, u2ID])
            try await createTeam(app: app, token: u1.token, leagueID: leagueID, name: "Team B", userIDs: [u3ID, u4ID])

            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let pickOrder = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: try race.requireID())
            let tokenByUserID = [u1ID: u1.token, u2ID: u2.token, u3ID: u3.token, u4ID: u4.token]
            let driverByUserID = [
                u1ID: try driver1.requireID(),
                u2ID: try driver2.requireID(),
                u3ID: try driver3.requireID(),
                u4ID: try driver4.requireID()
            ]

            try await makePicksForOrder(
                app: app,
                leagueID: leagueID,
                raceID: try race.requireID(),
                pickOrder: pickOrder,
                tokenByUserID: tokenByUserID,
                driverByUserID: driverByUserID
            )

            try await insertRaceResults(
                app: app,
                raceID: try race.requireID(),
                f1TeamID: f1Team.id,
                results: [
                    (driverID: try driver1.requireID(), points: 25),
                    (driverID: try driver2.requireID(), points: 15),
                    (driverID: try driver3.requireID(), points: 10),
                    (driverID: try driver4.requireID(), points: 8)
                ]
            )
            try await markRaceCompleted(app: app, raceID: try race.requireID())

            let standings = try await fetchTeamStandings(app: app, token: u1.token, leagueID: leagueID)
            XCTAssertEqual(standings.count, 2)

            let byName = Dictionary(uniqueKeysWithValues: standings.map { ($0.name, $0) })
            XCTAssertEqual(byName["Team A"]?.total_points, 40)
            XCTAssertEqual(byName["Team B"]?.total_points, 18)
            XCTAssertEqual(standings.first?.name, "Team A")
        }
    }
}
