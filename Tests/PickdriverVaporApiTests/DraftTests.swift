//
//  DraftTests.swift
//  PickdriverVaporApiTests
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class DraftTests: XCTestCase {

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

    // MARK: - Helpers

    private func createLeague(
        app: Application,
        token: String,
        name: String = "Draft League",
        maxPlayers: Int,
        teamsEnabled: Bool = false,
        bansEnabled: Bool = false,
        mirrorEnabled: Bool
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

    private func joinLeague(
        app: Application,
        token: String,
        code: String
    ) async throws {

        try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(JoinLeaguePayload(code: code))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func startDraft(
        app: Application,
        token: String,
        leagueID: Int
    ) async throws {
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

    private func getDeadlines(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int
    ) async throws -> DraftDeadline {
        var deadlines: DraftDeadline?

        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/deadlines", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            deadlines = try res.content.decode(DraftDeadline.self)
        })

        return try XCTUnwrap(deadlines)
    }

    private func getRaceDraft(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int
    ) async throws -> RaceDraft {
        var draft: RaceDraft?

        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            draft = try res.content.decode(RaceDraft.self)
        })

        return try XCTUnwrap(draft)
    }

    private func fetchLeagueFromDB(app: Application, leagueID: Int) async throws -> League {
        guard let league = try await League.find(leagueID, on: app.db) else {
            XCTFail("League not found in DB")
            throw Abort(.notFound)
        }
        return league
    }

    private func countRaceDraftsInDB(app: Application, leagueID: Int) async throws -> Int {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
        struct Row: Decodable { let count: Int }

        let row = try await sql.raw("SELECT COUNT(*)::int AS count FROM race_drafts WHERE league_id = \(bind: leagueID)")
            .first(decoding: Row.self)

        return row?.count ?? 0
    }

    private func fetchRaceDraftRow(app: Application, leagueID: Int, raceID: Int) async throws -> (draftID: Int, currentPickIndex: Int, mirrorPicks: Bool) {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
        struct Row: Decodable {
            let id: Int
            let current_pick_index: Int
            let mirror_picks: Bool
        }

        let row = try await sql.raw("""
            SELECT id, current_pick_index, mirror_picks
            FROM race_drafts
            WHERE league_id = \(bind: leagueID) AND race_id = \(bind: raceID)
            LIMIT 1
        """).first(decoding: Row.self)

        let r = try XCTUnwrap(row, "race_drafts row not found")
        return (draftID: r.id, currentPickIndex: r.current_pick_index, mirrorPicks: r.mirror_picks)
    }

    private func assertSameSecond(_ a: Date, _ b: Date, toleranceSeconds: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        let diff = abs(a.timeIntervalSince1970 - b.timeIntervalSince1970)
        XCTAssertLessThanOrEqual(diff, toleranceSeconds, "Dates differ by \(diff)s", file: file, line: line)
    }

    // MARK: - Tests

    func testStartDraftActivatesLeagueAndCreatesRaceDrafts_noMirror() async throws {
        try await withTestApp { app in
            // Seed: active season required for createLeague
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            // Seed: 2 upcoming races (completed=false), with raceTime sorted + fp1Time set (needed for deadlines)
            let now = Date()
            let fp1Race1 = now.addingTimeInterval(7 * 24 * 3600)       // +7d
            let fp1Race2 = now.addingTimeInterval(14 * 24 * 3600)      // +14d

            let race1 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Race 1",
                completed: false,
                fp1Time: fp1Race1,
                raceTime: fp1Race1.addingTimeInterval(2 * 24 * 3600)   // +2d after FP1
            )
            let race2 = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 2,
                name: "Race 2",
                completed: false,
                fp1Time: fp1Race2,
                raceTime: fp1Race2.addingTimeInterval(2 * 24 * 3600)
            )

            // Users + League
            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Draft League NoMirror",
                maxPlayers: 3,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: false
            )

            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await joinLeague(app: app, token: u3.token, code: league.code)

            // Start draft
            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            // Assert: league activated + initialRaceRound set to first upcoming race
            let dbLeague = try await fetchLeagueFromDB(app: app, leagueID: leagueID)
            XCTAssertEqual(dbLeague.status, "active")
            XCTAssertEqual(dbLeague.initialRaceRound, 1)

            // Assert: drafts created for races from initial round (2 races => 2 rows)
            let draftsCount = try await countRaceDraftsInDB(app: app, leagueID: leagueID)
            XCTAssertEqual(draftsCount, 2)

            // Assert: pick order endpoint exists and contains exactly all users once
            let race1ID = try race1.requireID()
            let race2ID = try race2.requireID()

            let order1 = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: race1ID)
            let order2 = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: race2ID)

            let expectedUsers = Set([try XCTUnwrap(u1.publicUser.id), try XCTUnwrap(u2.publicUser.id), try XCTUnwrap(u3.publicUser.id)])
            XCTAssertEqual(order1.count, expectedUsers.count)
            XCTAssertEqual(Set(order1), expectedUsers)

            XCTAssertEqual(order2.count, expectedUsers.count)
            XCTAssertEqual(Set(order2), expectedUsers)

            // Assert: rotation property (race2 order is race1 rotated by 1)
            // activateDraft rotates by i % baseOrder.count, with i starting at 0 for first race in allRaces.
            // Since our allRaces are round 1 then round 2, race2 corresponds to i=1.
            let rotated1By1 = Array(order1.dropFirst(1)) + Array(order1.prefix(1))
            XCTAssertEqual(order2, rotated1By1)

            // Assert: deadlines computed from FP1
            let dl1 = try await getDeadlines(app: app, token: u1.token, leagueID: leagueID, raceID: race1ID)
            XCTAssertEqual(dl1.leagueID, leagueID)
            XCTAssertEqual(dl1.raceID, race1ID)
            assertSameSecond(dl1.secondHalfDeadline, fp1Race1)
            assertSameSecond(dl1.firstHalfDeadline, fp1Race1.addingTimeInterval(-36 * 3600))

            // Assert: GET /draft/:raceID returns a RaceDraft with currentPickIndex=0 and mirrorPicks=false
            let draft1 = try await getRaceDraft(app: app, token: u1.token, leagueID: leagueID, raceID: race1ID)
            XCTAssertEqual(draft1.raceID, race1ID)
            XCTAssertEqual(draft1.currentPickIndex, 0)
            XCTAssertFalse(draft1.mirrorPicks)
            XCTAssertEqual(draft1.pickOrder, order1)

            // Assert: DB row aligns
            let row = try await fetchRaceDraftRow(app: app, leagueID: leagueID, raceID: race1ID)
            XCTAssertEqual(row.currentPickIndex, 0)
            XCTAssertEqual(row.mirrorPicks, false)

            // Silence unused warning
            _ = try race2.requireID()
        }
    }

    func testStartDraftCreatesMirrorPickOrders_whenMirrorEnabled() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let now = Date()
            let fp1 = now.addingTimeInterval(7 * 24 * 3600)

            // Only one upcoming race needed to validate mirror behavior
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Race Mirror",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Draft League Mirror",
                maxPlayers: 3,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: true
            )
            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await joinLeague(app: app, token: u3.token, code: league.code)

            try await startDraft(app: app, token: u1.token, leagueID: leagueID)

            let raceID = try race.requireID()
            let order = try await getPickOrder(app: app, token: u1.token, leagueID: leagueID, raceID: raceID)

            // In mirror mode: pickOrder = rotated + rotated.reversed()
            XCTAssertEqual(order.count, 3 * 2)

            let firstHalf = Array(order.prefix(3))
            let secondHalf = Array(order.suffix(3))
            XCTAssertEqual(secondHalf, firstHalf.reversed())

            // Validate "set" is still the same user ids, but appearing twice
            let expectedUsers = Set([try XCTUnwrap(u1.publicUser.id), try XCTUnwrap(u2.publicUser.id), try XCTUnwrap(u3.publicUser.id)])
            XCTAssertEqual(Set(firstHalf), expectedUsers)
            XCTAssertEqual(Set(secondHalf), expectedUsers)

            // GET draft should reflect mirrorPicks=true and same pickOrder
            let draft = try await getRaceDraft(app: app, token: u1.token, leagueID: leagueID, raceID: raceID)
            XCTAssertTrue(draft.mirrorPicks)
            XCTAssertEqual(draft.pickOrder, order)

            // DB row mirrors flag too
            let row = try await fetchRaceDraftRow(app: app, leagueID: leagueID, raceID: raceID)
            XCTAssertEqual(row.mirrorPicks, true)
        }
    }

    func testStartDraftFailsWhenNotAllPlayersJoined() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            // Need at least 1 upcoming race or start-draft will fail for another reason
            let now = Date()
            let fp1 = now.addingTimeInterval(7 * 24 * 3600)
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: 1,
                round: 1,
                name: "Race",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Draft League NotFull",
                maxPlayers: 3,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: false
            )
            let leagueID = try XCTUnwrap(league.id)

            // Only 1 join (total members=2, maxPlayers=3) => should fail
            try await joinLeague(app: app, token: u2.token, code: league.code)

            try await app.test(.POST, "/api/leagues/\(leagueID)/start-draft", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: u1.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("not all players"), "Unexpected reason: \(err.reason)")
            })
        }
    }

    func testPickOrderAndDeadlinesReturn404WhenDraftNotCreated() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let now = Date()
            let fp1 = now.addingTimeInterval(7 * 24 * 3600)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Race",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
            )

            let u1 = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: u1.token,
                name: "Draft League NoDraftYet",
                maxPlayers: 3,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: false
            )
            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: u2.token, code: league.code)
            try await joinLeague(app: app, token: u3.token, code: league.code)

            let raceID = try race.requireID()

            // pick-order should 404 (draft not created yet)
            try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/pick-order", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: u1.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            })

            // deadlines should 404 as well (LeagueController checks draft exists)
            try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/deadlines", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: u1.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            })
        }
    }
}
