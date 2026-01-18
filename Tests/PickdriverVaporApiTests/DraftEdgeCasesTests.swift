//
//  DraftEdgeCasesTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class DraftEdgeCasesTests: XCTestCase {

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
        driverID: Int,
        expectedStatus: HTTPResponseStatus = .ok
    ) async throws -> APIErrorResponse? {
        var error: APIErrorResponse?

        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/pick", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PickPayload(driverID: driverID))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, expectedStatus)
            if res.status != .ok {
                error = try res.content.decode(APIErrorResponse.self)
            }
        })

        return error
    }

    // MARK: - Helpers (DB)

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
    }

    private func fetchRaceDraftRow(
        app: Application,
        leagueID: Int,
        raceID: Int
    ) async throws -> (draftID: Int, currentPickIndex: Int, pickOrder: [Int]) {
        let sql = try sql(app)
        struct Row: Decodable {
            let id: Int
            let current_pick_index: Int
            let pick_order: [Int]
        }

        let row = try await sql.raw("""
            SELECT id, current_pick_index, pick_order
            FROM race_drafts
            WHERE league_id = \(bind: leagueID) AND race_id = \(bind: raceID)
            LIMIT 1
        """).first(decoding: Row.self)

        let r = try XCTUnwrap(row, "race_drafts row not found")
        return (draftID: r.id, currentPickIndex: r.current_pick_index, pickOrder: r.pick_order)
    }

    private func updateCurrentPickIndex(app: Application, draftID: Int, index: Int) async throws {
        let sql = try sql(app)
        try await sql.raw("""
            UPDATE race_drafts
            SET current_pick_index = \(bind: index)
            WHERE id = \(bind: draftID)
        """).run()
    }

    private func pickExists(app: Application, draftID: Int, userID: Int) async throws -> Bool {
        let sql = try sql(app)
        struct Row: Decodable { let id: Int }

        let row = try await sql.raw("""
            SELECT id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
            LIMIT 1
        """).first(decoding: Row.self)

        return row != nil
    }

    // MARK: - Tests

    func testAutoSkipAdvancesTurnWhenFirstDeadlinePassed() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Edge Team", color: "#666666")

            let driver1 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Skip",
                lastName: "One",
                driverNumber: 10,
                driverCode: "SK1"
            )
            let driver2 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Pick",
                lastName: "Two",
                driverNumber: 20,
                driverCode: "PK2"
            )

            let now = Date()
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Deadline GP",
                completed: false,
                fp1Time: now.addingTimeInterval(3600),
                raceTime: now.addingTimeInterval(2 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "AutoSkip League",
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
            let firstUserID = pickOrder[0]
            let secondUserID = pickOrder[1]

            let tokenByUserID = [u1ID: u1.token, u2ID: u2.token]
            let pickerToken = try XCTUnwrap(tokenByUserID[secondUserID])

            let pickerDriverID = secondUserID == u1ID ? try driver1.requireID() : try driver2.requireID()
            _ = try await makePick(
                app: app,
                token: pickerToken,
                leagueID: leagueID,
                raceID: try race.requireID(),
                driverID: pickerDriverID
            )

            let draftRow = try await fetchRaceDraftRow(app: app, leagueID: leagueID, raceID: try race.requireID())
            XCTAssertEqual(draftRow.currentPickIndex, 2)

            let firstPickExists = try await pickExists(app: app, draftID: draftRow.draftID, userID: firstUserID)
            let secondPickExists = try await pickExists(app: app, draftID: draftRow.draftID, userID: secondUserID)
            XCTAssertFalse(firstPickExists)
            XCTAssertTrue(secondPickExists)
        }
    }

    func testDraftAlreadyCompletedReturnsBadRequest() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Completed Team", color: "#777777")

            let driver = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Done",
                lastName: "Pick",
                driverNumber: 12,
                driverCode: "DON"
            )

            let now = Date()
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Completed GP",
                completed: false,
                fp1Time: now.addingTimeInterval(48 * 3600),
                raceTime: now.addingTimeInterval(50 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Completed Draft League",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let draftRow = try await fetchRaceDraftRow(app: app, leagueID: leagueID, raceID: try race.requireID())
            try await updateCurrentPickIndex(app: app, draftID: draftRow.draftID, index: draftRow.pickOrder.count)

            let error = try await makePick(
                app: app,
                token: u1.token,
                leagueID: leagueID,
                raceID: try race.requireID(),
                driverID: try driver.requireID(),
                expectedStatus: .badRequest
            )
            XCTAssertTrue(error?.reason.lowercased().contains("already completed") == true)
        }
    }

    func testDraftPastRaceRejected() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Past Team", color: "#888888")

            let driver = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Past",
                lastName: "Driver",
                driverNumber: 14,
                driverCode: "PST"
            )

            let now = Date()
            let pastRace = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Past GP",
                completed: false,
                fp1Time: now.addingTimeInterval(-5 * 3600),
                raceTime: now.addingTimeInterval(-3 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Past Race League",
                maxPlayers: 2,
                teamsEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let error = try await makePick(
                app: app,
                token: u1.token,
                leagueID: leagueID,
                raceID: try pastRace.requireID(),
                driverID: try driver.requireID(),
                expectedStatus: .badRequest
            )
            XCTAssertTrue(error?.reason.lowercased().contains("race already started") == true)
        }
    }
}

