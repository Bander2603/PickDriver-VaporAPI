import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class PickDriverV2Tests: XCTestCase {
    private struct SlotRow: Decodable {
        let pick_index: Int
        let driver_id: Int?
    }

    func testResolutionBanRecalculationAndFullValueMaterialization() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app: app, teamsEnabled: false)
            let deadline = fixture.fp1.addingTimeInterval(-24 * 3600)

            try await PickDriverV2Service.resolveIfDue(
                draftID: fixture.draftID,
                now: deadline,
                on: app.db
            )
            let initiallyResolved = try await slotDriverIDs(app: app, draftID: fixture.draftID)
            XCTAssertEqual(initiallyResolved, [fixture.driverIDs[0], fixture.driverIDs[1], fixture.driverIDs[2]])

            let result = try await PickDriverV2Service.ban(
                leagueID: fixture.leagueID,
                raceID: fixture.raceID,
                actorUserID: fixture.userIDs[2],
                targetUserID: fixture.userIDs[0],
                driverID: fixture.driverIDs[0],
                now: deadline.addingTimeInterval(60),
                on: app.db
            )
            XCTAssertEqual(result.resolutionRevision, 2)
            let recalculated = try await slotDriverIDs(app: app, draftID: fixture.draftID)
            XCTAssertEqual(recalculated, [fixture.driverIDs[1], fixture.driverIDs[0], fixture.driverIDs[2]])

            try await PickDriverV2Service.resolveIfDue(
                draftID: fixture.draftID,
                now: fixture.fp1,
                on: app.db
            )

            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            struct PickRow: Decodable {
                let driver_id: Int
                let is_autopick: Bool
            }
            let picks = try await sql.raw("""
                SELECT driver_id, is_autopick
                FROM player_picks
                WHERE draft_id = \(bind: fixture.draftID) AND is_banned = false
                ORDER BY id
            """).all(decoding: PickRow.self)
            XCTAssertEqual(Set(picks.map(\.driver_id)), Set(fixture.driverIDs[0...2]))
            XCTAssertTrue(picks.allSatisfy { !$0.is_autopick })
        }
    }

    func testEmptyOrExhaustedPreferenceProducesMissedPick() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app: app, teamsEnabled: false)
            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            try await sql.raw("""
                UPDATE player_pick_preferences
                SET driver_order = '{}'::integer[]
                WHERE league_id = \(bind: fixture.leagueID)
                  AND user_id = \(bind: fixture.userIDs[1])
            """).run()

            try await PickDriverV2Service.resolveIfDue(
                draftID: fixture.draftID,
                now: fixture.fp1.addingTimeInterval(-24 * 3600),
                on: app.db
            )
            let slots = try await slotRows(app: app, draftID: fixture.draftID)
            XCTAssertEqual(slots.count, 3)
            XCTAssertNil(slots[1].driver_id)
        }
    }

    func testTeammateCannotBeBanned() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app: app, teamsEnabled: true)
            let leagueTeam = LeagueTeam(name: "Same team", leagueID: fixture.leagueID)
            try await leagueTeam.save(on: app.db)
            let otherTeam = LeagueTeam(name: "Other team", leagueID: fixture.leagueID)
            try await otherTeam.save(on: app.db)
            let sharedTeamID = try leagueTeam.requireID()
            let otherTeamID = try otherTeam.requireID()
            try await TeamMember(userID: fixture.userIDs[0], teamID: sharedTeamID).save(on: app.db)
            try await TeamMember(userID: fixture.userIDs[2], teamID: sharedTeamID).save(on: app.db)
            try await TeamMember(userID: fixture.userIDs[1], teamID: otherTeamID).save(on: app.db)

            let deadline = fixture.fp1.addingTimeInterval(-24 * 3600)
            try await PickDriverV2Service.resolveIfDue(draftID: fixture.draftID, now: deadline, on: app.db)
            do {
                _ = try await PickDriverV2Service.ban(
                    leagueID: fixture.leagueID,
                    raceID: fixture.raceID,
                    actorUserID: fixture.userIDs[2],
                    targetUserID: fixture.userIDs[0],
                    driverID: fixture.driverIDs[0],
                    now: deadline.addingTimeInterval(60),
                    on: app.db
                )
                XCTFail("Expected teammate ban to be rejected")
            } catch let abort as any AbortError {
                XCTAssertEqual(abort.status, .forbidden)
            }
        }
    }

    func testNonTeamBanLimitIsSharedAcrossLeagueSeason() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app: app, teamsEnabled: false)
            let firstDeadline = fixture.fp1.addingTimeInterval(-24 * 3600)
            try await PickDriverV2Service.resolveIfDue(draftID: fixture.draftID, now: firstDeadline, on: app.db)
            _ = try await PickDriverV2Service.ban(
                leagueID: fixture.leagueID,
                raceID: fixture.raceID,
                actorUserID: fixture.userIDs[2],
                targetUserID: fixture.userIDs[0],
                driverID: fixture.driverIDs[0],
                now: firstDeadline.addingTimeInterval(60),
                on: app.db
            )

            let second = try await createAdditionalDraft(app: app, fixture: fixture, round: 15)
            try await PickDriverV2Service.resolveIfDue(draftID: second.draftID, now: second.deadline, on: app.db)
            _ = try await PickDriverV2Service.ban(
                leagueID: fixture.leagueID,
                raceID: second.raceID,
                actorUserID: fixture.userIDs[2],
                targetUserID: fixture.userIDs[0],
                driverID: fixture.driverIDs[0],
                now: second.deadline.addingTimeInterval(60),
                on: app.db
            )

            let third = try await createAdditionalDraft(app: app, fixture: fixture, round: 16)
            try await PickDriverV2Service.resolveIfDue(draftID: third.draftID, now: third.deadline, on: app.db)
            do {
                _ = try await PickDriverV2Service.ban(
                    leagueID: fixture.leagueID,
                    raceID: third.raceID,
                    actorUserID: fixture.userIDs[2],
                    targetUserID: fixture.userIDs[0],
                    driverID: fixture.driverIDs[0],
                    now: third.deadline.addingTimeInterval(60),
                    on: app.db
                )
                XCTFail("Expected the third seasonal ban to be rejected")
            } catch let abort as any AbortError {
                XCTAssertEqual(abort.status, .badRequest)
            }
        }
    }

    private struct Fixture {
        let leagueID: Int
        let raceID: Int
        let draftID: Int
        let userIDs: [Int]
        let driverIDs: [Int]
        let fp1: Date
    }

    private func makeFixture(app: Application, teamsEnabled: Bool) async throws -> Fixture {
        let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
        let seasonID = try season.requireID()
        let f1Team = try await TestSeed.createF1Team(app: app, seasonID: seasonID)
        var driverIDs: [Int] = []
        for index in 0..<4 {
            let driver = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: f1Team.id,
                lastName: "V2-\(index)",
                driverNumber: 40 + index,
                driverCode: "V\(index)X"
            )
            driverIDs.append(try driver.requireID())
        }

        var userIDs: [Int] = []
        for index in 0..<3 {
            let user = User(
                username: "v2_user_\(index)_\(UUID().uuidString.prefix(6))",
                email: "v2_\(index)_\(UUID().uuidString.prefix(6))@test.com",
                passwordHash: "hash",
                emailVerified: true
            )
            try await user.save(on: app.db)
            userIDs.append(try user.requireID())
        }

        let league = League(
            name: "V2 test",
            code: "V2\(UUID().uuidString.prefix(8))",
            status: "active",
            initialRaceRound: 14,
            creatorID: userIDs[0],
            teamsEnabled: teamsEnabled,
            bansEnabled: true,
            mirrorEnabled: false,
            maxPlayers: 3,
            seasonID: seasonID
        )
        try await league.save(on: app.db)
        let leagueID = try league.requireID()
        for userID in userIDs {
            try await LeagueMember(userID: userID, leagueID: leagueID).save(on: app.db)
        }

        let fp1 = Date().addingTimeInterval(48 * 3600)
        let race = try await TestSeed.createRace(
            app: app,
            seasonID: seasonID,
            round: 14,
            name: "Dutch GP V2",
            completed: false,
            fp1Time: fp1,
            raceTime: fp1.addingTimeInterval(48 * 3600)
        )
        let raceID = try race.requireID()
        let draft = RaceDraft(
            leagueID: leagueID,
            raceID: raceID,
            pickOrder: userIDs,
            mirrorPicks: false,
            status: "active",
            gameplayVersion: .v2
        )
        try await draft.save(on: app.db)
        let draftID = try draft.requireID()

        let preferences = [
            [driverIDs[0], driverIDs[1], driverIDs[2], driverIDs[3]],
            [driverIDs[0], driverIDs[1], driverIDs[2], driverIDs[3]],
            [driverIDs[1], driverIDs[2], driverIDs[3], driverIDs[0]]
        ]
        for (index, userID) in userIDs.enumerated() {
            try await PlayerPickPreference(
                leagueID: leagueID,
                userID: userID,
                driverOrder: preferences[index]
            ).save(on: app.db)
        }

        return Fixture(
            leagueID: leagueID,
            raceID: raceID,
            draftID: draftID,
            userIDs: userIDs,
            driverIDs: driverIDs,
            fp1: fp1
        )
    }

    private func slotRows(app: Application, draftID: Int) async throws -> [SlotRow] {
        let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
        return try await sql.raw("""
            SELECT pick_index, driver_id
            FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
            ORDER BY pick_index
        """).all(decoding: SlotRow.self)
    }

    private func slotDriverIDs(app: Application, draftID: Int) async throws -> [Int?] {
        try await slotRows(app: app, draftID: draftID).map(\.driver_id)
    }

    private func createAdditionalDraft(
        app: Application,
        fixture: Fixture,
        round: Int
    ) async throws -> (raceID: Int, draftID: Int, deadline: Date) {
        guard let firstRace = try await Race.find(fixture.raceID, on: app.db) else {
            throw Abort(.notFound)
        }
        let fp1 = fixture.fp1.addingTimeInterval(TimeInterval(round - 13) * 7 * 24 * 3600)
        let race = try await TestSeed.createRace(
            app: app,
            seasonID: firstRace.seasonID,
            round: round,
            name: "V2 round \(round)",
            completed: false,
            fp1Time: fp1,
            raceTime: fp1.addingTimeInterval(48 * 3600)
        )
        let raceID = try race.requireID()
        let draft = RaceDraft(
            leagueID: fixture.leagueID,
            raceID: raceID,
            pickOrder: fixture.userIDs,
            mirrorPicks: false,
            status: "active",
            gameplayVersion: .v2
        )
        try await draft.save(on: app.db)
        return (raceID, try draft.requireID(), fp1.addingTimeInterval(-24 * 3600))
    }
}
