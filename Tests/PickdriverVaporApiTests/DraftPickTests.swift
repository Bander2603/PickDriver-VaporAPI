//
//  DraftPickTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 17.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class DraftPickTests: XCTestCase {

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

    private struct BanPayload: Content {
        let targetUserID: Int
        let driverID: Int
    }

    // Mirror of DraftController.DraftResponse (kept local so tests don’t depend on controller internals)
    private struct DraftResponseDTO: Content {
        let status: String
        let currentPickIndex: Int
        let nextUserID: Int?
        let bannedDriverIDs: [Int]
        let pickedDriverIDs: [Int]
        let yourTurn: Bool
        let yourDeadline: Date
    }

    // MARK: - Helpers (API)

    private func createLeague(
        app: Application,
        token: String,
        name: String = "DraftPick League",
        maxPlayers: Int,
        teamsEnabled: Bool = false,
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

    private func getPickOrder(app: Application, token: String, leagueID: Int, raceID: Int) async throws -> [Int] {
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
    ) async throws -> DraftResponseDTO {
        var dto: DraftResponseDTO?

        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/pick", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PickPayload(driverID: driverID))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            dto = try res.content.decode(DraftResponseDTO.self)
        })

        return try XCTUnwrap(dto)
    }

    private func banPick(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int,
        targetUserID: Int,
        driverID: Int,
        expectedStatus: HTTPResponseStatus = .ok
    ) async throws -> DraftResponseDTO? {
        var dto: DraftResponseDTO?

        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/ban", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(BanPayload(targetUserID: targetUserID, driverID: driverID))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, expectedStatus)
            if res.status == .ok {
                dto = try res.content.decode(DraftResponseDTO.self)
            }
        })

        return dto
    }

    // MARK: - Helpers (DB)

    private func fetchRaceDraftRow(app: Application, leagueID: Int, raceID: Int) async throws -> (draftID: Int, currentPickIndex: Int, pickOrder: [Int]) {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
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

    private func fetchPickRow(app: Application, draftID: Int, userID: Int) async throws -> (driverID: Int, isBanned: Bool, bannedBy: Int?)? {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
        struct Row: Decodable {
            let driver_id: Int
            let is_banned: Bool
            let banned_by: Int?
        }

        let row = try await sql.raw("""
            SELECT driver_id, is_banned, banned_by
            FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
            ORDER BY id DESC
            LIMIT 1
        """).first(decoding: Row.self)

        guard let r = row else { return nil }
        return (driverID: r.driver_id, isBanned: r.is_banned, bannedBy: r.banned_by)
    }

    private func fetchBansRemaining(app: Application, draftID: Int, userID: Int) async throws -> Int? {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
        struct Row: Decodable { let bans_remaining: Int }

        let row = try await sql.raw("""
            SELECT bans_remaining
            FROM player_bans
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
              AND is_team_scope = false
            LIMIT 1
        """).first(decoding: Row.self)

        return row?.bans_remaining
    }

    private func assertSameSecond(_ a: Date, _ b: Date, toleranceSeconds: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        let diff = abs(a.timeIntervalSince1970 - b.timeIntervalSince1970)
        XCTAssertLessThanOrEqual(diff, toleranceSeconds, "Dates differ by \(diff)s", file: file, line: line)
    }

    private struct UsersByID {
        let map: [Int: TestAuth.CreatedUser]
        func token(for userID: Int) -> String {
            map[userID]!.token
        }
    }

    // MARK: - Seed Scenario

    private func seedSimpleDraft3Players(app: Application) async throws -> (
        leagueID: Int,
        leagueCode: String,
        raceID: Int,
        fp1: Date,
        users: UsersByID,
        driverIDs: [Int]
    ) {
        let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
        let seasonID = try season.requireID()

        // Need at least one race with FP1 for deadlines
        let now = Date()
        let fp1 = now.addingTimeInterval(7 * 24 * 3600)
        let race = try await TestSeed.createRace(
            app: app,
            seasonID: seasonID,
            round: 1,
            name: "Race DraftPick",
            completed: false,
            fp1Time: fp1,
            raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
        )
        let raceID = try race.requireID()

        // Need drivers in DB
        let f1Team = try await TestSeed.createF1Team(app: app, seasonID: seasonID, name: "Seed Team", color: "#000000")
        let d1 = try await TestSeed.createDriver(app: app, seasonID: seasonID, f1TeamID: f1Team.id, firstName: "A", lastName: "One", driverNumber: 11, driverCode: "A11")
        let d2 = try await TestSeed.createDriver(app: app, seasonID: seasonID, f1TeamID: f1Team.id, firstName: "B", lastName: "Two", driverNumber: 22, driverCode: "B22")
        let d3 = try await TestSeed.createDriver(app: app, seasonID: seasonID, f1TeamID: f1Team.id, firstName: "C", lastName: "Three", driverNumber: 33, driverCode: "C33")

        let driverIDs = [try d1.requireID(), try d2.requireID(), try d3.requireID()]

        // Users
        let u1 = try await TestAuth.register(app: app)
        let u2 = try await TestAuth.register(app: app)
        let u3 = try await TestAuth.register(app: app)

        // League (teams disabled, mirror disabled)
        let league = try await createLeague(
            app: app,
            token: u1.token,
            name: "DraftPick League",
            maxPlayers: 3,
            teamsEnabled: false,
            bansEnabled: true,
            mirrorEnabled: false
        )
        let leagueID = try XCTUnwrap(league.id)

        // Join rest
        try await joinLeague(app: app, token: u2.token, code: league.code)
        try await joinLeague(app: app, token: u3.token, code: league.code)

        // Start draft
        try await startDraft(app: app, token: u1.token, leagueID: leagueID)

        let id1 = try XCTUnwrap(u1.publicUser.id)
        let id2 = try XCTUnwrap(u2.publicUser.id)
        let id3 = try XCTUnwrap(u3.publicUser.id)

        let users = UsersByID(map: [id1: u1, id2: u2, id3: u3])

        return (leagueID: leagueID, leagueCode: league.code, raceID: raceID, fp1: fp1, users: users, driverIDs: driverIDs)
    }

    // MARK: - Tests

    func testMakePickHappyPath_advancesTurn_andCreatesPlayerPickRow() async throws {
        try await withTestApp { app in
            let seeded = try await seedSimpleDraft3Players(app: app)

            // Determine order dynamically (it is randomized)
            let anyToken = seeded.users.map.values.first!.token
            let order = try await getPickOrder(app: app, token: anyToken, leagueID: seeded.leagueID, raceID: seeded.raceID)

            XCTAssertEqual(order.count, 3)

            let firstUserID = order[0]
            let secondUserID = order[1]

            let firstToken = seeded.users.token(for: firstUserID)

            // Pick driver
            let driverID = seeded.driverIDs[0]
            let res = try await makePick(app: app, token: firstToken, leagueID: seeded.leagueID, raceID: seeded.raceID, driverID: driverID)

            XCTAssertEqual(res.status, "ok")
            XCTAssertEqual(res.currentPickIndex, 1)
            XCTAssertEqual(res.nextUserID, secondUserID)
            XCTAssertFalse(res.yourTurn)
            XCTAssertEqual(res.bannedDriverIDs, [])
            XCTAssertTrue(res.pickedDriverIDs.contains(driverID))

            // Deadline: first user should receive firstHalfDeadline (fp1 - 36h)
            let expectedFirstHalf = Calendar.current.date(byAdding: .hour, value: -36, to: seeded.fp1)!
            assertSameSecond(res.yourDeadline, expectedFirstHalf)

            // DB asserts
            let draftRow = try await fetchRaceDraftRow(app: app, leagueID: seeded.leagueID, raceID: seeded.raceID)
            XCTAssertEqual(draftRow.currentPickIndex, 1)

            let pickRow = try await fetchPickRow(app: app, draftID: draftRow.draftID, userID: firstUserID)
            XCTAssertNotNil(pickRow)
            XCTAssertEqual(pickRow?.driverID, driverID)
            XCTAssertEqual(pickRow?.isBanned, false)
            XCTAssertNil(pickRow?.bannedBy)
        }
    }

    func testMakePickFailsWhenNotYourTurn_returnsForbidden() async throws {
        try await withTestApp { app in
            let seeded = try await seedSimpleDraft3Players(app: app)

            let anyToken = seeded.users.map.values.first!.token
            let order = try await getPickOrder(app: app, token: anyToken, leagueID: seeded.leagueID, raceID: seeded.raceID)

            let firstUserID = order[0]
            let thirdUserID = order[2]

            // First user makes a valid pick
            _ = try await makePick(
                app: app,
                token: seeded.users.token(for: firstUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                driverID: seeded.driverIDs[0]
            )

            // Third user attempts to pick out of turn -> 403
            try await app.test(.POST, "/api/leagues/\(seeded.leagueID)/draft/\(seeded.raceID)/pick", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: seeded.users.token(for: thirdUserID))
                try req.content.encode(PickPayload(driverID: seeded.driverIDs[1]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("not your turn"), "Unexpected reason: \(err.reason)")
            })
        }
    }

    func testMakePickConflictWhenDriverAlreadyPicked_returnsConflict() async throws {
        try await withTestApp { app in
            let seeded = try await seedSimpleDraft3Players(app: app)

            let anyToken = seeded.users.map.values.first!.token
            let order = try await getPickOrder(app: app, token: anyToken, leagueID: seeded.leagueID, raceID: seeded.raceID)

            let firstUserID = order[0]
            let secondUserID = order[1]

            let driverID = seeded.driverIDs[0]

            // First pick OK
            _ = try await makePick(
                app: app,
                token: seeded.users.token(for: firstUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                driverID: driverID
            )

            // Second user tries to pick same driver -> 409
            try await app.test(.POST, "/api/leagues/\(seeded.leagueID)/draft/\(seeded.raceID)/pick", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: seeded.users.token(for: secondUserID))
                try req.content.encode(PickPayload(driverID: driverID))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("already picked"), "Unexpected reason: \(err.reason)")
            })
        }
    }

    func testBanPickHappyPath_marksPickBanned_rewindsTurn_andConsumesBan() async throws {
        try await withTestApp { app in
            let seeded = try await seedSimpleDraft3Players(app: app)

            let anyToken = seeded.users.map.values.first!.token
            let order = try await getPickOrder(app: app, token: anyToken, leagueID: seeded.leagueID, raceID: seeded.raceID)

            let firstUserID = order[0]
            let secondUserID = order[1]

            let pickedDriverID = seeded.driverIDs[0]

            // First user picks
            _ = try await makePick(
                app: app,
                token: seeded.users.token(for: firstUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                driverID: pickedDriverID
            )

            // Second user bans previous pick (first user's pick)
            let banRes = try await banPick(
                app: app,
                token: seeded.users.token(for: secondUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                targetUserID: firstUserID,
                driverID: pickedDriverID,
                expectedStatus: .ok
            )

            let dto = try XCTUnwrap(banRes)
            XCTAssertEqual(dto.status, "ok")

            // After ban, controller rewinds currentPickIndex to targetIndex (first user's index)
            XCTAssertEqual(dto.currentPickIndex, 0)
            XCTAssertEqual(dto.nextUserID, firstUserID)

            XCTAssertTrue(dto.bannedDriverIDs.contains(pickedDriverID))

            // pickedDriverIDs should be empty now (the only pick is banned)
            XCTAssertEqual(dto.pickedDriverIDs, [])

            // DB asserts
            let draftRow = try await fetchRaceDraftRow(app: app, leagueID: seeded.leagueID, raceID: seeded.raceID)

            let pickRow = try await fetchPickRow(app: app, draftID: draftRow.draftID, userID: firstUserID)
            XCTAssertNotNil(pickRow)
            XCTAssertEqual(pickRow?.driverID, pickedDriverID)
            XCTAssertEqual(pickRow?.isBanned, true)
            XCTAssertEqual(pickRow?.bannedBy, secondUserID)

            // bans_remaining should be created and decremented: default 2 -> after ban => 1
            let remaining = try await fetchBansRemaining(app: app, draftID: draftRow.draftID, userID: secondUserID)
            XCTAssertEqual(remaining, 1)
        }
    }

    func testBanPickFailsWhenNotPreviousPicker_returnsForbidden() async throws {
        try await withTestApp { app in
            let seeded = try await seedSimpleDraft3Players(app: app)

            let anyToken = seeded.users.map.values.first!.token
            let order = try await getPickOrder(app: app, token: anyToken, leagueID: seeded.leagueID, raceID: seeded.raceID)

            let firstUserID = order[0]
            let secondUserID = order[1]
            let thirdUserID = order[2]

            let pickedDriverID = seeded.driverIDs[0]

            // First user picks
            _ = try await makePick(
                app: app,
                token: seeded.users.token(for: firstUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                driverID: pickedDriverID
            )

            // Third user tries to ban first user's pick (but only the next user in order should be allowed)
            try await app.test(.POST, "/api/leagues/\(seeded.leagueID)/draft/\(seeded.raceID)/ban", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: seeded.users.token(for: thirdUserID))
                try req.content.encode(BanPayload(targetUserID: firstUserID, driverID: pickedDriverID))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("only ban"), "Unexpected reason: \(err.reason)")
            })

            // Sanity: second user should still be able to ban (not asserting full response again, just status)
            _ = try await banPick(
                app: app,
                token: seeded.users.token(for: secondUserID),
                leagueID: seeded.leagueID,
                raceID: seeded.raceID,
                targetUserID: firstUserID,
                driverID: pickedDriverID,
                expectedStatus: .ok
            )
        }
    }
}
