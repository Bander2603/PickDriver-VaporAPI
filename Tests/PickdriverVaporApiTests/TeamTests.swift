//
//  TeamTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
import Fluent
import Vapor
@testable import PickdriverVaporApi

final class TeamTests: XCTestCase {

    // MARK: - Request payloads

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
        let userIDs: [Int]?

        enum CodingKeys: String, CodingKey {
            case leagueID = "league_id"
            case name
            case userIDs = "user_ids"
        }
    }

    private struct UpdateTeamPayload: Content {
        let name: String
        let userIDs: [Int]?

        enum CodingKeys: String, CodingKey {
            case name
            case userIDs = "user_ids"
        }
    }

    private struct AssignUserPayload: Content {
        let userID: Int
    }

    // MARK: - Helpers

    private func createLeague(
        app: Application,
        token: String,
        name: String = "Team League",
        maxPlayers: Int = 4,
        teamsEnabled: Bool = true,
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

    private func joinLeague(
        app: Application,
        token: String,
        code: String
    ) async throws -> League.Public {

        var league: League.Public?

        try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(JoinLeaguePayload(code: code))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            league = try res.content.decode(League.Public.self)
        })

        return try XCTUnwrap(league)
    }

    private func createTeam(
        app: Application,
        token: String,
        leagueID: Int,
        name: String,
        userIDs: [Int]
    ) async throws -> LeagueTeam {

        var created: LeagueTeam?

        try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateTeamPayload(leagueID: leagueID, name: name, userIDs: userIDs))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            created = try res.content.decode(LeagueTeam.self)
        })

        return try XCTUnwrap(created)
    }

    // MARK: - Tests

    func testCreateTeamHappyPath_createsTeamAndAssignments() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)
            let u4 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "Liga Teams",
                maxPlayers: 4,
                teamsEnabled: true
            )

            // make them members
            _ = try await joinLeague(app: app, token: u2.token, code: league.code)
            _ = try await joinLeague(app: app, token: u3.token, code: league.code)
            _ = try await joinLeague(app: app, token: u4.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)

            let team = try await createTeam(
                app: app,
                token: creator.token,
                leagueID: leagueID,
                name: "Team A",
                userIDs: [id1, id2]
            )

            let teamID = try XCTUnwrap(team.id)
            XCTAssertEqual(team.name, "Team A")

            // DB assertions: 2 assignments exist
            let members = try await TeamMember.query(on: app.db)
                .filter(\.$team.$id == teamID)
                .all()

            XCTAssertEqual(members.count, 2)

            let memberUserIDs = Set(members.map { $0.$user.id })
            XCTAssertTrue(memberUserIDs.contains(id1))
            XCTAssertTrue(memberUserIDs.contains(id2))
        }
    }

    func testCreateTeamFailsWhenTeamsDisabled() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "Liga NoTeams",
                maxPlayers: 4,
                teamsEnabled: false
            )

            _ = try await joinLeague(app: app, token: u2.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)

            try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(CreateTeamPayload(leagueID: leagueID, name: "Team X", userIDs: [id1, id2]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("not allowed"))
            })
        }
    }

    func testCreateTeamFailsWhenLessThan2Players() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let league = try await createLeague(app: app, token: creator.token, maxPlayers: 2, teamsEnabled: true)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)

            try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(CreateTeamPayload(leagueID: leagueID, name: "Team A", userIDs: [id1]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("at least 2"))
            })
        }
    }

    func testCreateTeamFailsWhenTooManyPlayersForLeagueSize() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            // 3 members => maxPerTeam = ceil(3/2)=2, so 3 user_ids must fail
            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)

            let league = try await createLeague(app: app, token: creator.token, maxPlayers: 3, teamsEnabled: true)
            _ = try await joinLeague(app: app, token: u2.token, code: league.code)
            _ = try await joinLeague(app: app, token: u3.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)
            let id3 = try XCTUnwrap(u3.publicUser.id)

            try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(CreateTeamPayload(leagueID: leagueID, name: "Team A", userIDs: [id1, id2, id3]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("at most"))
            })
        }
    }

    func testUpdateTeamHappyPath_updatesNameAndReplacesMembers() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            // 4 members => maxPerTeam = 2
            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)
            let u4 = try await TestAuth.register(app: app)

            let league = try await createLeague(app: app, token: creator.token, maxPlayers: 4, teamsEnabled: true)
            _ = try await joinLeague(app: app, token: u2.token, code: league.code)
            _ = try await joinLeague(app: app, token: u3.token, code: league.code)
            _ = try await joinLeague(app: app, token: u4.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)
            let id3 = try XCTUnwrap(u3.publicUser.id)
            let id4 = try XCTUnwrap(u4.publicUser.id)

            let team = try await createTeam(app: app, token: creator.token, leagueID: leagueID, name: "Team A", userIDs: [id1, id2])
            let teamID = try XCTUnwrap(team.id)

            // Update: rename + swap members to (u3,u4)
            var updated: LeagueTeam?
            try await app.test(.PUT, "/api/teams/\(teamID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(UpdateTeamPayload(name: "Team A+", userIDs: [id3, id4]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                updated = try res.content.decode(LeagueTeam.self)
            })

            XCTAssertEqual(updated?.name, "Team A+")

            // DB: members replaced
            let members = try await TeamMember.query(on: app.db)
                .filter(\.$team.$id == teamID)
                .all()

            XCTAssertEqual(members.count, 2)
            let userIDs = Set(members.map { $0.$user.id })
            XCTAssertTrue(userIDs.contains(id3))
            XCTAssertTrue(userIDs.contains(id4))
            XCTAssertFalse(userIDs.contains(id1))
            XCTAssertFalse(userIDs.contains(id2))
        }
    }

    func testDeleteTeam_removesTeamAndMembers() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)

            let league = try await createLeague(app: app, token: creator.token, maxPlayers: 2, teamsEnabled: true)
            _ = try await joinLeague(app: app, token: u2.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)

            let team = try await createTeam(app: app, token: creator.token, leagueID: leagueID, name: "Team A", userIDs: [id1, id2])
            let teamID = try XCTUnwrap(team.id)

            // Delete
            try await app.test(.DELETE, "/api/teams/\(teamID)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            // DB: team is gone, members are gone
            let dbTeam = try await LeagueTeam.find(teamID, on: app.db)
            XCTAssertNil(dbTeam)

            let assignments = try await TeamMember.query(on: app.db)
                .filter(\.$team.$id == teamID)
                .count()

            XCTAssertEqual(assignments, 0)
        }
    }

    func testAssignUserToTeamHappyPath_andConflictWhenAlreadyAssigned() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            // league maxPlayers=4 => assign endpoint uses maxPerTeam = league.maxPlayers / 2 = 2
            let creator = try await TestAuth.register(app: app)
            let u2 = try await TestAuth.register(app: app)
            let u3 = try await TestAuth.register(app: app)
            let u4 = try await TestAuth.register(app: app)

            let league = try await createLeague(app: app, token: creator.token, maxPlayers: 4, teamsEnabled: true)
            _ = try await joinLeague(app: app, token: u2.token, code: league.code)
            _ = try await joinLeague(app: app, token: u3.token, code: league.code)
            _ = try await joinLeague(app: app, token: u4.token, code: league.code)

            let leagueID = try XCTUnwrap(league.id)
            let id1 = try XCTUnwrap(creator.publicUser.id)
            let id2 = try XCTUnwrap(u2.publicUser.id)
            let id3 = try XCTUnwrap(u3.publicUser.id)
            let id4 = try XCTUnwrap(u4.publicUser.id)

            let teamA = try await createTeam(app: app, token: creator.token, leagueID: leagueID, name: "Team A", userIDs: [id1, id2])
            let teamAID = try XCTUnwrap(teamA.id)

            let teamB = try await createTeam(app: app, token: creator.token, leagueID: leagueID, name: "Team B", userIDs: [id3, id4])
            let teamBID = try XCTUnwrap(teamB.id)

            // Create a fresh member (u5) to assign via /assign
            let u5 = try await TestAuth.register(app: app)
            _ = try await joinLeague(app: app, token: u5.token, code: league.code)
            let id5 = try XCTUnwrap(u5.publicUser.id)

            // Assign u5 to teamA should FAIL because teamA is full (2/2) -> 409
            try await app.test(.POST, "/api/teams/\(teamAID)/assign", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(AssignUserPayload(userID: id5))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("full"))
            })

            // Remove one member from teamB by updating it to have only two other users? (it already has 2)
            // Instead: create a new empty-ish team is not allowed (<2). So to test happy-path assign,
            // we create a league with maxPlayers=6 where maxPerTeam=3, and then assign into a team with 2 members.

            // Minimal happy-path assign in separate league:
            let league2 = try await createLeague(app: app, token: creator.token, name: "Liga Assign OK", maxPlayers: 6, teamsEnabled: true)
            _ = try await joinLeague(app: app, token: u2.token, code: league2.code)
            _ = try await joinLeague(app: app, token: u3.token, code: league2.code)

            let league2ID = try XCTUnwrap(league2.id)
            let team2 = try await createTeam(app: app, token: creator.token, leagueID: league2ID, name: "Team 2", userIDs: [id1, id2])
            let team2ID = try XCTUnwrap(team2.id)

            // u3 is member of league2 and NOT assigned yet -> assign OK (maxPerTeam=3)
            try await app.test(.POST, "/api/teams/\(team2ID)/assign", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(AssignUserPayload(userID: id3))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            // Assign u3 again anywhere within same league2 -> 409 conflict "already assigned"
            try await app.test(.POST, "/api/teams/\(team2ID)/assign", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
                try req.content.encode(AssignUserPayload(userID: id3))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("already"))
            })
        }
    }

    func testTeamEndpointsRequireToken() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/teams", beforeRequest: { req async throws in
                try req.content.encode(CreateTeamPayload(leagueID: 1, name: "No token", userIDs: [1, 2]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.PUT, "/api/teams/1", beforeRequest: { req async throws in
                try req.content.encode(UpdateTeamPayload(name: "No token", userIDs: [1, 2]))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.DELETE, "/api/teams/1", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.POST, "/api/teams/1/assign", beforeRequest: { req async throws in
                try req.content.encode(AssignUserPayload(userID: 1))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }
}
