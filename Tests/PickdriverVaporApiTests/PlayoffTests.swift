import XCTVapor
import SQLKit
import Fluent
@testable import PickdriverVaporApi

final class PlayoffTests: XCTestCase {
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

    private struct PlayoffPickPositionPayload: Content {
        let pickPosition: Int
    }

    private struct PlayoffStatus: Content {
        let enabled: Bool
        let status: String
        let regularRaceCount: Int
        let playoffRaceIDs: [Int]
        let firstPlayoffRaceID: Int?
        let seedOrder: [Int]
        let topGroupSize: Int?
        let selectedPickPositionByUserID: [String: Int]
        let nextSelectorUserID: Int?
        let firstPickOrder: [Int]
    }

    private func makeUTCDate(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private func createLeague(app: Application, token: String, maxPlayers: Int, mirrorEnabled: Bool) async throws -> League.Public {
        var league: League.Public?
        try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateLeaguePayload(
                name: "Playoff League",
                maxPlayers: maxPlayers,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: mirrorEnabled
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            league = try res.content.decode(League.Public.self)
        })
        return try XCTUnwrap(league)
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

    private func playoffStatus(app: Application, token: String, leagueID: Int) async throws -> PlayoffStatus {
        var status: PlayoffStatus?
        try await app.test(.GET, "/api/leagues/\(leagueID)/playoffs", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            status = try res.content.decode(PlayoffStatus.self)
        })
        return try XCTUnwrap(status)
    }

    private func choosePlayoffPosition(
        app: Application,
        token: String,
        leagueID: Int,
        position: Int
    ) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/playoffs/pick-order", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PlayoffPickPositionPayload(pickPosition: position))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func pickOrder(app: Application, token: String, leagueID: Int, raceID: Int) async throws -> [Int] {
        var order: [Int] = []
        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/pick-order", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            order = try res.content.decode([Int].self)
        })
        return order
    }

    private func draftDeadlines(app: Application, token: String, leagueID: Int, raceID: Int) async throws -> DraftDeadline {
        var deadlines: DraftDeadline?
        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/deadlines", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            deadlines = try res.content.decode(DraftDeadline.self)
        })
        return try XCTUnwrap(deadlines)
    }

    private func makePick(app: Application, token: String, leagueID: Int, raceID: Int, driverID: Int) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/pick", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(["driverID": driverID])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testPlayoffsUseRankedGroupsAndRotateMirrorPicksIndependently() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2030, active: true)
            let seasonID = try season.requireID()
            let fp1Start = makeUTCDate(year: 2030, month: 4, day: 1)

            var races: [Race] = []
            for round in 1...22 {
                let fp1 = fp1Start.addingTimeInterval(TimeInterval((round - 1) * 7 * 24 * 3600))
                races.append(try await TestSeed.createRace(
                    app: app,
                    seasonID: seasonID,
                    round: round,
                    name: "Race \(round)",
                    completed: false,
                    fp1Time: fp1,
                    raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
                ))
            }

            let users = try await (1...8).asyncMap { index in
                try await TestAuth.register(app: app, username: "playoff_\(index)", email: "playoff_\(index)@test.com")
            }
            let league = try await createLeague(app: app, token: users[0].token, maxPlayers: 8, mirrorEnabled: true)
            let leagueID = try XCTUnwrap(league.id)
            for user in users.dropFirst() {
                try await joinLeague(app: app, token: user.token, code: league.code)
            }

            let rankedUserIDs = try users.map { try XCTUnwrap($0.publicUser.id) }
            let members = try await LeagueMember.query(on: app.db)
                .filter(\.$league.$id == leagueID)
                .all()
            for (index, userID) in rankedUserIDs.enumerated() {
                let member = try XCTUnwrap(members.first(where: { $0.$user.id == userID }))
                member.pickOrder = index + 1
                try await member.save(on: app.db)
            }

            try await startDraft(app: app, token: users[0].token, leagueID: leagueID)

            let firstPlayoffRaceID = try races[16].requireID()
            let secondPlayoffRaceID = try races[17].requireID()
            let pendingPlayoffOrder = try await pickOrder(
                app: app,
                token: users[0].token,
                leagueID: leagueID,
                raceID: firstPlayoffRaceID
            )
            XCTAssertEqual(pendingPlayoffOrder, [])

            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: seasonID, name: "Playoff Team")
            let firstRegularRaceID = try races[0].requireID()
            let firstRegularDraftQuery = try await RaceDraft.query(on: app.db)
                .filter(\.$league.$id == leagueID)
                .filter(\.$raceID == firstRegularRaceID)
                .first()
            let firstRegularDraft = try XCTUnwrap(firstRegularDraftQuery)
            let firstRegularDraftID = try firstRegularDraft.requireID()
            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))

            for (index, userID) in rankedUserIDs.enumerated() {
                let driver = try await TestSeed.createDriver(
                    app: app,
                    seasonID: seasonID,
                    f1TeamID: f1Team.id,
                    firstName: "Driver",
                    lastName: "\(index)",
                    driverNumber: index + 1,
                    driverCode: "P\(index)"
                )
                let driverID = try driver.requireID()
                try await DraftPick(draftID: firstRegularDraftID, userID: userID, driverID: driverID).save(on: app.db)
                try await sql.raw("""
                    INSERT INTO race_results (race_id, driver_id, points)
                    VALUES (\(bind: firstRegularRaceID), \(bind: driverID), \(bind: 80 - index))
                """).run()
            }

            for race in races.prefix(16) {
                race.setStatus(.completed)
                try await race.save(on: app.db)
            }

            let selecting = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            XCTAssertTrue(selecting.enabled)
            XCTAssertEqual(selecting.status, "selecting")
            XCTAssertEqual(selecting.regularRaceCount, 16)
            XCTAssertEqual(selecting.playoffRaceIDs.count, 6)
            XCTAssertEqual(selecting.firstPlayoffRaceID, firstPlayoffRaceID)
            XCTAssertEqual(selecting.seedOrder, rankedUserIDs)
            XCTAssertEqual(selecting.topGroupSize, 4)
            XCTAssertEqual(selecting.nextSelectorUserID, rankedUserIDs[0])

            try await choosePlayoffPosition(app: app, token: users[0].token, leagueID: leagueID, position: 4)
            try await choosePlayoffPosition(app: app, token: users[1].token, leagueID: leagueID, position: 2)
            try await choosePlayoffPosition(app: app, token: users[2].token, leagueID: leagueID, position: 1)
            try await choosePlayoffPosition(app: app, token: users[3].token, leagueID: leagueID, position: 3)
            try await choosePlayoffPosition(app: app, token: users[4].token, leagueID: leagueID, position: 8)
            try await choosePlayoffPosition(app: app, token: users[5].token, leagueID: leagueID, position: 5)
            try await choosePlayoffPosition(app: app, token: users[6].token, leagueID: leagueID, position: 6)

            let finalized = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            XCTAssertEqual(finalized.status, "finalized")
            XCTAssertEqual(finalized.selectedPickPositionByUserID[String(rankedUserIDs[7])], 7)

            let firstTopGroup = [rankedUserIDs[2], rankedUserIDs[1], rankedUserIDs[3], rankedUserIDs[0]]
            let firstBottomGroup = [rankedUserIDs[5], rankedUserIDs[6], rankedUserIDs[7], rankedUserIDs[4]]
            let firstExpected = firstTopGroup + firstBottomGroup + firstTopGroup.reversed() + firstBottomGroup.reversed()
            XCTAssertEqual(finalized.firstPickOrder, firstExpected)
            let firstPlayoffOrder = try await pickOrder(
                app: app,
                token: users[0].token,
                leagueID: leagueID,
                raceID: firstPlayoffRaceID
            )
            XCTAssertEqual(firstPlayoffOrder, firstExpected)

            let firstPlayoffDeadlines = try await draftDeadlines(
                app: app,
                token: users[0].token,
                leagueID: leagueID,
                raceID: firstPlayoffRaceID
            )
            XCTAssertEqual(firstPlayoffDeadlines.firstHalfDeadline, races[16].fp1Time)
            XCTAssertEqual(firstPlayoffDeadlines.secondHalfDeadline, races[16].fp1Time)

            let secondTopGroup = [rankedUserIDs[1], rankedUserIDs[3], rankedUserIDs[0], rankedUserIDs[2]]
            let secondBottomGroup = [rankedUserIDs[6], rankedUserIDs[7], rankedUserIDs[4], rankedUserIDs[5]]
            let secondExpected = secondTopGroup + secondBottomGroup + secondTopGroup.reversed() + secondBottomGroup.reversed()
            let secondPlayoffOrder = try await pickOrder(
                app: app,
                token: users[0].token,
                leagueID: leagueID,
                raceID: secondPlayoffRaceID
            )
            XCTAssertEqual(secondPlayoffOrder, secondExpected)
        }
    }

    func testExpiredPlayoffSelectionRandomizesOnlyRemainingGroupPositions() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2031, active: true)
            let seasonID = try season.requireID()
            let fp1Start = makeUTCDate(year: 2031, month: 5, day: 1)
            var races: [Race] = []
            for round in 1...5 {
                let fp1 = fp1Start.addingTimeInterval(TimeInterval((round - 1) * 7 * 24 * 3600))
                races.append(try await TestSeed.createRace(
                    app: app,
                    seasonID: seasonID,
                    round: round,
                    name: "Deadline Race \(round)",
                    completed: false,
                    fp1Time: fp1,
                    raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
                ))
            }

            let users = try await (1...4).asyncMap { index in
                try await TestAuth.register(app: app, username: "deadline_\(index)", email: "deadline_\(index)@test.com")
            }
            let league = try await createLeague(app: app, token: users[0].token, maxPlayers: 4, mirrorEnabled: false)
            let leagueID = try XCTUnwrap(league.id)
            for user in users.dropFirst() {
                try await joinLeague(app: app, token: user.token, code: league.code)
            }
            try await startDraft(app: app, token: users[0].token, leagueID: leagueID)

            for race in races.prefix(4) {
                race.setStatus(.completed)
                try await race.save(on: app.db)
            }

            let selecting = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            XCTAssertEqual(selecting.status, "selecting")
            XCTAssertEqual(selecting.playoffRaceIDs.count, 1)
            try await choosePlayoffPosition(app: app, token: users[0].token, leagueID: leagueID, position: 2)

            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            try await sql.raw("""
                UPDATE league_playoffs
                SET selection_deadline = NOW() - INTERVAL '1 second'
                WHERE league_id = \(bind: leagueID)
            """).run()

            let finalized = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            let firstUserID = try XCTUnwrap(users[0].publicUser.id)
            XCTAssertEqual(finalized.status, "finalized")
            XCTAssertEqual(finalized.selectedPickPositionByUserID.count, 4)
            XCTAssertEqual(finalized.selectedPickPositionByUserID.values.sorted(), [1, 2, 3, 4])
            XCTAssertEqual(finalized.selectedPickPositionByUserID[String(firstUserID)], 2)

            let playoffOrder = try await pickOrder(
                app: app,
                token: users[0].token,
                leagueID: leagueID,
                raceID: try races[4].requireID()
            )
            XCTAssertEqual(playoffOrder.count, 4)
            XCTAssertEqual(Set(playoffOrder).count, 4)
        }
    }

    func testUnselectedBracketIsRecalculatedWhenAPlayoffRaceIsCancelled() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2033, active: true)
            let seasonID = try season.requireID()
            let fp1 = makeUTCDate(year: 2033, month: 7, day: 1)
            var races: [Race] = []
            for round in 1...5 {
                let raceFP1 = fp1.addingTimeInterval(TimeInterval((round - 1) * 7 * 24 * 3600))
                let race = try await TestSeed.createRace(
                    app: app,
                    seasonID: seasonID,
                    round: round,
                    name: "Calendar Race \(round)",
                    completed: false,
                    fp1Time: raceFP1,
                    raceTime: raceFP1.addingTimeInterval(2 * 24 * 3600)
                )
                races.append(race)
            }

            var users: [TestAuth.CreatedUser] = []
            for index in 1...4 {
                users.append(try await TestAuth.register(
                    app: app,
                    username: "calendar_\(index)",
                    email: "calendar_\(index)@test.com"
                ))
            }
            let league = try await createLeague(app: app, token: users[0].token, maxPlayers: 4, mirrorEnabled: false)
            let leagueID = try XCTUnwrap(league.id)
            for user in users.dropFirst() {
                try await joinLeague(app: app, token: user.token, code: league.code)
            }
            try await startDraft(app: app, token: users[0].token, leagueID: leagueID)

            for race in races.prefix(4) {
                race.setStatus(.completed)
                try await race.save(on: app.db)
            }

            let selecting = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            XCTAssertEqual(selecting.status, "selecting")
            XCTAssertEqual(selecting.playoffRaceIDs, [try races[4].requireID()])

            races[4].setStatus(.cancelled)
            try await races[4].save(on: app.db)
            _ = try await RaceCancellationService.invalidateCancelledDraftIfNeeded(
                raceID: try races[4].requireID(),
                on: app.db
            )

            let recalculated = try await playoffStatus(app: app, token: users[0].token, leagueID: leagueID)
            XCTAssertEqual(recalculated.status, "not_applicable")
            XCTAssertFalse(recalculated.enabled)
        }
    }

    func testScheduleSynchronizationNeverResetsAnInProgressRegularDraft() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2032, active: true)
            let seasonID = try season.requireID()
            let fp1 = makeUTCDate(year: 2032, month: 6, day: 1)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: seasonID,
                round: 1,
                name: "Regular Race",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 24 * 3600)
            )
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: seasonID,
                round: 2,
                name: "Regular Race 2",
                completed: false,
                fp1Time: fp1.addingTimeInterval(7 * 24 * 3600),
                raceTime: fp1.addingTimeInterval(9 * 24 * 3600)
            )

            let users = try await (1...2).asyncMap { index in
                try await TestAuth.register(app: app, username: "sync_\(index)", email: "sync_\(index)@test.com")
            }
            let league = try await createLeague(app: app, token: users[0].token, maxPlayers: 2, mirrorEnabled: false)
            let leagueID = try XCTUnwrap(league.id)
            try await joinLeague(app: app, token: users[1].token, code: league.code)
            try await startDraft(app: app, token: users[0].token, leagueID: leagueID)

            let raceID = try race.requireID()
            let initialOrder = try await pickOrder(app: app, token: users[0].token, leagueID: leagueID, raceID: raceID)
            let firstUserID = try XCTUnwrap(initialOrder.first)
            let firstUserIndex = try XCTUnwrap(users.firstIndex { $0.publicUser.id == firstUserID })
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: seasonID, name: "Sync Team")
            let driver = try await TestSeed.createDriver(app: app, seasonID: seasonID, f1TeamID: f1Team.id, driverNumber: 66, driverCode: "SYN")
            try await makePick(
                app: app,
                token: users[firstUserIndex].token,
                leagueID: leagueID,
                raceID: raceID,
                driverID: try driver.requireID()
            )

            _ = try await pickOrder(app: app, token: users[0].token, leagueID: leagueID, raceID: raceID)

            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            struct DraftState: Decodable {
                let current_pick_index: Int
                let pick_count: Int
            }
            let state = try await sql.raw("""
                SELECT
                    rd.current_pick_index,
                    COUNT(pp.id)::int AS pick_count
                FROM race_drafts rd
                LEFT JOIN player_picks pp ON pp.draft_id = rd.id AND pp.is_banned = false
                WHERE rd.league_id = \(bind: leagueID)
                  AND rd.race_id = \(bind: raceID)
                GROUP BY rd.current_pick_index
            """).first(decoding: DraftState.self)
            XCTAssertEqual(state?.current_pick_index, 1)
            XCTAssertEqual(state?.pick_count, 1)
        }
    }
}

private extension Collection {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
