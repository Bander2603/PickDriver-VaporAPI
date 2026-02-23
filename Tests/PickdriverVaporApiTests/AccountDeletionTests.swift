//
//  AccountDeletionTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 23.02.26.
//

import XCTVapor
import SQLKit
import Fluent
@testable import PickdriverVaporApi

final class AccountDeletionTests: XCTestCase {

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

    private func createLeague(
        app: Application,
        token: String,
        name: String,
        maxPlayers: Int
    ) async throws -> League.Public {
        var created: League.Public?

        try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateLeaguePayload(
                name: name,
                maxPlayers: maxPlayers,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: false
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

    private func deleteAccount(app: Application, token: String) async throws {
        try await app.test(.DELETE, "/api/auth/account", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
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

    func testDeleteAccountPendingMemberRemovesMembershipAndFreesSlot() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let owner = try await TestAuth.register(app: app)
            let toDelete = try await TestAuth.register(app: app)
            let replacement = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: owner.token,
                name: "Pending Delete Member",
                maxPlayers: 2
            )
            let leagueID = try XCTUnwrap(league.id)
            let deletedUserID = try XCTUnwrap(toDelete.publicUser.id)

            try await joinLeague(app: app, token: toDelete.token, code: league.code)
            try await deleteAccount(app: app, token: toDelete.token)

            let deletedMembership = try await LeagueMember.query(on: app.db)
                .filter(\.$league.$id == leagueID)
                .filter(\.$user.$id == deletedUserID)
                .first()
            XCTAssertNil(deletedMembership)

            let memberCountAfterDeletion = try await LeagueMember.query(on: app.db)
                .filter(\.$league.$id == leagueID)
                .count()
            XCTAssertEqual(memberCountAfterDeletion, 1)

            try await joinLeague(app: app, token: replacement.token, code: league.code)

            let deletedUser = try await User.find(deletedUserID, on: app.db)
            XCTAssertNotNil(deletedUser?.deletedAt)
            XCTAssertTrue(deletedUser?.username.contains("usuario borrado") == true)

            try await app.test(.GET, "/api/auth/profile", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: toDelete.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testDeleteAccountPendingOwnerDeletesLeague() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, active: true)

            let owner = try await TestAuth.register(app: app)
            let joiner = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: owner.token,
                name: "Pending Owner Deletion",
                maxPlayers: 2
            )
            let leagueID = try XCTUnwrap(league.id)

            try await joinLeague(app: app, token: joiner.token, code: league.code)
            try await deleteAccount(app: app, token: owner.token)

            let deletedLeague = try await League.find(leagueID, on: app.db)
            XCTAssertNil(deletedLeague)
        }
    }

    func testDeleteAccountActiveMemberKeepsLeagueAndAutoSkipsTurn() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let f1Team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Deletion Team", color: "#111111")

            let driver1 = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Delete",
                lastName: "Skip",
                driverNumber: 7,
                driverCode: "DSK"
            )

            _ = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: f1Team.id,
                firstName: "Second",
                lastName: "Driver",
                driverNumber: 8,
                driverCode: "SDR"
            )

            let now = Date()
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Delete User GP",
                completed: false,
                fp1Time: now.addingTimeInterval(48 * 3600),
                raceTime: now.addingTimeInterval(50 * 3600)
            )

            let owner = try await TestAuth.register(app: app)
            let toDelete = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: owner.token,
                name: "Active Delete Member",
                maxPlayers: 2
            )
            let leagueID = try XCTUnwrap(league.id)
            let ownerID = try XCTUnwrap(owner.publicUser.id)
            let deletedUserID = try XCTUnwrap(toDelete.publicUser.id)
            let raceID = try race.requireID()

            try await joinLeague(app: app, token: toDelete.token, code: league.code)
            try await startDraft(app: app, token: owner.token, leagueID: leagueID)

            let sql = try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
            try await sql.raw("""
                UPDATE race_drafts
                SET pick_order = \(bind: [deletedUserID, ownerID]),
                    current_pick_index = 0
                WHERE league_id = \(bind: leagueID)
                  AND race_id = \(bind: raceID)
            """).run()

            try await deleteAccount(app: app, token: toDelete.token)

            try await makePick(
                app: app,
                token: owner.token,
                leagueID: leagueID,
                raceID: raceID,
                driverID: try driver1.requireID()
            )

            struct DraftStateRow: Decodable {
                let current_pick_index: Int
            }
            let draftState = try await sql.raw("""
                SELECT current_pick_index
                FROM race_drafts
                WHERE league_id = \(bind: leagueID)
                  AND race_id = \(bind: raceID)
                LIMIT 1
            """).first(decoding: DraftStateRow.self)
            XCTAssertEqual(draftState?.current_pick_index, 2)

            struct CountRow: Decodable {
                let count: Int
            }

            let deletedUserPickCount = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM player_picks
                WHERE draft_id = (
                    SELECT id FROM race_drafts
                    WHERE league_id = \(bind: leagueID)
                      AND race_id = \(bind: raceID)
                    LIMIT 1
                )
                  AND user_id = \(bind: deletedUserID)
                  AND is_banned = false
            """).first(decoding: CountRow.self)
            XCTAssertEqual(deletedUserPickCount?.count, 0)

            let memberCount = try await LeagueMember.query(on: app.db)
                .filter(\.$league.$id == leagueID)
                .count()
            XCTAssertEqual(memberCount, 2)
        }
    }
}
