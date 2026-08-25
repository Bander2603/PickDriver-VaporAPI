import Fluent
import SQLKit
import XCTVapor
@testable import PickdriverVaporApi

final class RaceDriverSubstitutionTests: XCTestCase {
    private let internalToken = "test-internal-token"

    private struct SlotRow: Decodable {
        let pick_index: Int
        let driver_id: Int?
        let original_driver_id: Int?
    }

    private struct PickRow: Decodable {
        let user_id: Int
        let driver_id: Int
        let original_driver_id: Int?
    }

    func testPreferenceTransformationUsesFrozenOrderForSubstitutionChain() {
        let substitutions = [
            RaceDriverSubstitutionPolicy.Definition(
                outgoingDriverID: 1,
                incomingDriverID: 2,
                f1TeamID: 10,
                announcedAt: nil
            ),
            RaceDriverSubstitutionPolicy.Definition(
                outgoingDriverID: 2,
                incomingDriverID: 3,
                f1TeamID: 20,
                announcedAt: nil
            )
        ]

        XCTAssertEqual(
            RaceDriverSubstitutionPolicy.candidates(for: [1, 2, 4], substitutions: substitutions),
            [
                .init(originalDriverID: 1, effectiveDriverID: 2),
                .init(originalDriverID: 2, effectiveDriverID: 3),
                .init(originalDriverID: 4, effectiveDriverID: 4)
            ]
        )
        XCTAssertEqual(
            RaceDriverSubstitutionPolicy.candidates(for: [2, 1, 4], substitutions: substitutions),
            [
                .init(originalDriverID: 2, effectiveDriverID: 2),
                .init(originalDriverID: 4, effectiveDriverID: 4)
            ]
        )
    }

    func testDryRunApplyAndRepeatedApplyReconcileFinalizedDraft() async throws {
        try await withTestApp { app in
            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let seasonID = try season.requireID()
            let redBull = try await TestSeed.createF1Team(
                app: app,
                seasonID: seasonID,
                name: "Red Bull",
                color: "#111111"
            )
            let racingBulls = try await TestSeed.createF1Team(
                app: app,
                seasonID: seasonID,
                name: "Racing Bulls",
                color: "#222222"
            )
            let otherTeam = try await TestSeed.createF1Team(
                app: app,
                seasonID: seasonID,
                name: "Other",
                color: "#333333"
            )

            let hadjar = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: redBull.id,
                firstName: "Isack",
                lastName: "Hadjar",
                driverNumber: 6,
                driverCode: "HAD"
            )
            let lawson = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: racingBulls.id,
                firstName: "Liam",
                lastName: "Lawson",
                driverNumber: 30,
                driverCode: "LAW"
            )
            let tsunoda = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: racingBulls.id,
                firstName: "Yuki",
                lastName: "Tsunoda",
                driverNumber: 22,
                driverCode: "TSU"
            )
            tsunoda.active = false
            try await tsunoda.save(on: app.db)
            let other = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: otherTeam.id,
                firstName: "Other",
                lastName: "Driver",
                driverNumber: 44,
                driverCode: "OTH"
            )

            let race = try await TestSeed.createRace(
                app: app,
                seasonID: seasonID,
                round: 14,
                name: "Dutch GP",
                completed: false,
                sprint: true,
                fp1Time: Date().addingTimeInterval(-3 * 24 * 3600),
                raceTime: Date().addingTimeInterval(-24 * 3600)
            )
            let raceID = try race.requireID()

            let userA = try await TestAuth.register(app: app)
            let userB = try await TestAuth.register(app: app)
            let userAID = try XCTUnwrap(userA.publicUser.id)
            let userBID = try XCTUnwrap(userB.publicUser.id)
            let league = League(
                name: "Substitution League",
                code: "SUB123",
                status: "active",
                initialRaceRound: 14,
                creatorID: userAID,
                maxPlayers: 2,
                seasonID: seasonID
            )
            try await league.save(on: app.db)
            let leagueID = try league.requireID()
            try await LeagueMember(userID: userAID, leagueID: leagueID).save(on: app.db)
            try await LeagueMember(userID: userBID, leagueID: leagueID).save(on: app.db)

            let draft = RaceDraft(
                leagueID: leagueID,
                raceID: raceID,
                pickOrder: [userAID, userBID],
                mirrorPicks: false,
                status: "completed",
                gameplayVersion: .v2
            )
            draft.currentPickIndex = 2
            draft.resolutionState = V2DraftResolutionState.finalized.rawValue
            draft.resolutionRevision = 1
            draft.resolvedAt = Date().addingTimeInterval(-2 * 24 * 3600)
            try await draft.save(on: app.db)
            let draftID = try draft.requireID()

            let hadjarID = try hadjar.requireID()
            let lawsonID = try lawson.requireID()
            let tsunodaID = try tsunoda.requireID()
            let otherID = try other.requireID()
            try await sql.raw("""
                INSERT INTO draft_pick_preference_snapshots (draft_id, user_id, driver_order)
                VALUES
                    (\(bind: draftID), \(bind: userAID), \(bind: [hadjarID, lawsonID, otherID])),
                    (\(bind: draftID), \(bind: userBID), \(bind: [hadjarID, lawsonID, otherID]))
            """).run()
            try await sql.raw("""
                INSERT INTO v2_draft_slots (
                    draft_id, pick_index, user_id, driver_id, is_mirror_pick, resolution_revision
                ) VALUES
                    (\(bind: draftID), 0, \(bind: userAID), \(bind: hadjarID), false, 1),
                    (\(bind: draftID), 1, \(bind: userBID), \(bind: lawsonID), false, 1)
            """).run()
            try await sql.raw("""
                INSERT INTO player_picks (
                    draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick
                ) VALUES
                    (\(bind: draftID), \(bind: userAID), \(bind: hadjarID), false, false, false),
                    (\(bind: draftID), \(bind: userBID), \(bind: lawsonID), false, false, false)
            """).run()

            let payload = RaceDriverSubstitutionService.Request(
                dryRun: true,
                substitutions: [
                    .init(
                        outgoingDriverID: hadjarID,
                        incomingDriverID: lawsonID,
                        f1TeamID: redBull.id,
                        announcedAt: nil
                    ),
                    .init(
                        outgoingDriverID: lawsonID,
                        incomingDriverID: tsunodaID,
                        f1TeamID: racingBulls.id,
                        announcedAt: nil
                    )
                ]
            )

            var dryRunResponse: RaceDriverSubstitutionService.Response?
            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/substitutions/reconcile",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                    try req.content.encode(payload)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    dryRunResponse = try res.content.decode(RaceDriverSubstitutionService.Response.self)
                }
            )
            XCTAssertEqual(dryRunResponse?.drafts.first?.changes.count, 2)
            XCTAssertTrue(dryRunResponse?.dryRun ?? false)
            let slotsAfterDryRun = try await self.slots(draftID: draftID, sql: sql)
            XCTAssertEqual(slotsAfterDryRun.map(\.driver_id), [hadjarID, lawsonID])

            let applyPayload = RaceDriverSubstitutionService.Request(
                dryRun: false,
                substitutions: payload.substitutions
            )
            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/substitutions/reconcile",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                    try req.content.encode(applyPayload)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    let response = try res.content.decode(RaceDriverSubstitutionService.Response.self)
                    XCTAssertEqual(response.drafts.first?.revisionAfter, 2)
                }
            )

            let reconciledSlots = try await slots(draftID: draftID, sql: sql)
            XCTAssertEqual(reconciledSlots.map(\.driver_id), [lawsonID, tsunodaID])
            XCTAssertEqual(reconciledSlots.map(\.original_driver_id), [hadjarID, lawsonID])

            let picks = try await sql.raw("""
                SELECT user_id, driver_id, original_driver_id
                FROM player_picks
                WHERE draft_id = \(bind: draftID) AND is_banned = false
                ORDER BY user_id
            """).all(decoding: PickRow.self)
            let pickByUser = Dictionary(uniqueKeysWithValues: picks.map { ($0.user_id, $0) })
            XCTAssertEqual(pickByUser[userAID]?.driver_id, lawsonID)
            XCTAssertEqual(pickByUser[userAID]?.original_driver_id, hadjarID)
            XCTAssertEqual(pickByUser[userBID]?.driver_id, tsunodaID)
            XCTAssertEqual(pickByUser[userBID]?.original_driver_id, lawsonID)

            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/substitutions/reconcile",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                    try req.content.encode(applyPayload)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    let response = try res.content.decode(RaceDriverSubstitutionService.Response.self)
                    XCTAssertTrue(response.drafts.first?.changes.isEmpty ?? false)
                    XCTAssertEqual(response.drafts.first?.revisionAfter, 2)
                }
            )

            try await sql.raw("""
                INSERT INTO race_results (
                    race_id, driver_id, points, sprint_points, f1_team_id
                ) VALUES
                    (\(bind: raceID), \(bind: lawsonID), 10, 2, \(bind: redBull.id)),
                    (\(bind: raceID), \(bind: tsunodaID), 6, 1, \(bind: racingBulls.id))
            """).run()
            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/results/publish",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                }
            )

            try await app.test(
                .GET,
                "/api/players/standings/players?league_id=\(leagueID)",
                beforeRequest: { req async throws in
                    req.headers.bearerAuthorization = .init(token: userA.token)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    let standings = try res.content.decode([PlayerStanding].self)
                    let pointsByUser = Dictionary(uniqueKeysWithValues: standings.map { ($0.user_id, $0.total_points) })
                    XCTAssertEqual(pointsByUser[userAID], 10)
                    XCTAssertEqual(pointsByUser[userBID], 6)
                }
            )

            try await app.test(
                .GET,
                "/api/players/standings/picks?league_id=\(leagueID)&user_id=\(userAID)",
                beforeRequest: { req async throws in
                    req.headers.bearerAuthorization = .init(token: userA.token)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    let history = try res.content.decode([PickHistory].self)
                    XCTAssertEqual(history.first?.driver_name, "Liam Lawson")
                    XCTAssertEqual(history.first?.original_driver_name, "Isack Hadjar")
                    XCTAssertEqual(history.first?.points, 10)
                }
            )

            try await app.test(.GET, "/api/standings/f1/drivers", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let standings = try res.content.decode([DriverStanding].self)
                let pointsByDriver = Dictionary(uniqueKeysWithValues: standings.map { ($0.driver_id, $0.points) })
                XCTAssertEqual(pointsByDriver[lawsonID], 12)
                XCTAssertEqual(pointsByDriver[tsunodaID], 7)
            })

            try await app.test(.GET, "/api/standings/f1/teams", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let standings = try res.content.decode([TeamStanding].self)
                let pointsByTeam = Dictionary(uniqueKeysWithValues: standings.map { ($0.team_id, $0.points) })
                XCTAssertEqual(pointsByTeam[redBull.id], 12)
                XCTAssertEqual(pointsByTeam[racingBulls.id], 7)
            })
        }
    }

    func testPublishingRejectsResultThatDoesNotMatchConfiguredRaceTeam() async throws {
        try await withTestApp { app in
            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let seasonID = try season.requireID()
            let originalTeam = try await TestSeed.createF1Team(app: app, seasonID: seasonID, name: "Original")
            let replacementTeam = try await TestSeed.createF1Team(app: app, seasonID: seasonID, name: "Replacement")
            let outgoing = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: originalTeam.id,
                driverNumber: 10,
                driverCode: "OUT"
            )
            let incoming = try await TestSeed.createDriver(
                app: app,
                seasonID: seasonID,
                f1TeamID: replacementTeam.id,
                driverNumber: 11,
                driverCode: "INN"
            )
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: seasonID,
                round: 14,
                name: "Roster Validation GP",
                completed: false
            )
            let raceID = try race.requireID()

            let request = RaceDriverSubstitutionService.Request(
                dryRun: false,
                substitutions: [
                    .init(
                        outgoingDriverID: try outgoing.requireID(),
                        incomingDriverID: try incoming.requireID(),
                        f1TeamID: originalTeam.id,
                        announcedAt: nil
                    )
                ]
            )
            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/substitutions/reconcile",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                    try req.content.encode(request)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                }
            )

            try await sql.raw("""
                INSERT INTO race_results (race_id, driver_id, points, f1_team_id)
                VALUES (
                    \(bind: raceID), \(bind: try incoming.requireID()), 10,
                    \(bind: replacementTeam.id)
                )
            """).run()

            try await app.test(
                .POST,
                "/api/internal/races/\(raceID)/results/publish",
                beforeRequest: { req async throws in
                    req.headers.replaceOrAdd(name: "X-Internal-Token", value: self.internalToken)
                },
                afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .conflict)
                }
            )
            let reloadedRace = try await Race.find(raceID, on: app.db)
            XCTAssertFalse(try XCTUnwrap(reloadedRace).completed)
        }
    }

    private func slots(draftID: Int, sql: any SQLDatabase) async throws -> [SlotRow] {
        try await sql.raw("""
            SELECT pick_index, driver_id, original_driver_id
            FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
            ORDER BY pick_index
        """).all(decoding: SlotRow.self)
    }
}
