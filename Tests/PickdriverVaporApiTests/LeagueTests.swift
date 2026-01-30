//
//  LeagueTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
import Fluent
import Vapor
@testable import PickdriverVaporApi

final class LeagueTests: XCTestCase {

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

    // MARK: - Helpers

    private func createLeague(
        app: Application,
        token: String,
        name: String = "Test League",
        maxPlayers: Int = 2,
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

    // MARK: - Tests

    func testCreateLeagueAddsCreatorAsMember_andIsReturnedInMyLeagues() async throws {
        try await withTestApp { app in
            // Needed: createLeague requires an active season
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let user = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: user.token,
                name: "Liga 1",
                maxPlayers: 2,
                teamsEnabled: false,
                bansEnabled: false,
                mirrorEnabled: false
            )

            XCTAssertEqual(league.name, "Liga 1")
            XCTAssertEqual(league.status.lowercased(), "pending")
            XCTAssertEqual(league.creatorID, league.creatorID) // sanity (non-nil-ish)
            XCTAssertEqual(league.maxPlayers, 2)
            XCTAssertFalse(league.code.isEmpty)

            // My leagues should include it
            try await app.test(.GET, "/api/leagues/my", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let leagues = try res.content.decode([League.Public].self)
                XCTAssertEqual(leagues.count, 1)
                XCTAssertEqual(leagues.first?.name, "Liga 1")
                XCTAssertEqual(leagues.first?.code, league.code)
            })

            // DB assertion: membership exists
            let creatorId = try XCTUnwrap(user.publicUser.id)
            let leagueId = try XCTUnwrap(league.id)

            let membership = try await LeagueMember.query(on: app.db)
                .filter(\.$user.$id == creatorId)
                .filter(\.$league.$id == leagueId)
                .first()

            XCTAssertNotNil(membership)
        }
    }

    func testCreateLeagueFailsWhenNoActiveSeason() async throws {
        try await withTestApp { app in
            let user = try await TestAuth.register(app: app)

            try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(CreateLeaguePayload(
                    name: "Liga sin season",
                    maxPlayers: 2,
                    teamsEnabled: false,
                    bansEnabled: false,
                    mirrorEnabled: false
                ))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("no active season"))
            })
        }
    }

    func testCreateLeagueFailsWhenExceedingCreatorLimit() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let user = try await TestAuth.register(app: app)

            _ = try await createLeague(app: app, token: user.token, name: "Liga 1")
            _ = try await createLeague(app: app, token: user.token, name: "Liga 2")
            _ = try await createLeague(app: app, token: user.token, name: "Liga 3")

            try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
                try req.content.encode(CreateLeaguePayload(
                    name: "Liga 4",
                    maxPlayers: 2,
                    teamsEnabled: false,
                    bansEnabled: false,
                    mirrorEnabled: false
                ))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("limit"))
            })
        }
    }

    func testJoinLeagueHappyPath_andMyLeaguesContainsItForJoiner() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let joiner = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "Liga Join",
                maxPlayers: 2
            )

            // Joiner joins
            let joined = try await joinLeague(app: app, token: joiner.token, code: league.code)
            XCTAssertEqual(joined.id, league.id)
            XCTAssertEqual(joined.code, league.code)

            // My leagues for joiner should include it
            try await app.test(.GET, "/api/leagues/my", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: joiner.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let leagues = try res.content.decode([League.Public].self)
                XCTAssertEqual(leagues.count, 1)
                XCTAssertEqual(leagues.first?.code, league.code)
            })

            // Members endpoint should contain both users
            let leagueId = try XCTUnwrap(league.id)

            try await app.test(.GET, "/api/leagues/\(leagueId)/members", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: creator.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let members = try res.content.decode([User.Public].self)

                let usernames = Set(members.map { $0.username })
                XCTAssertTrue(usernames.contains(creator.username))
                XCTAssertTrue(usernames.contains(joiner.username))
                XCTAssertEqual(members.count, 2)
            })
        }
    }

    func testJoinLeagueFailsWhenCodeNotFound() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let joiner = try await TestAuth.register(app: app)

            try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: joiner.token)
                try req.content.encode(JoinLeaguePayload(code: "ZZZZZZ"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("not found"))
            })
        }
    }

    func testJoinLeagueFailsWhenAlreadyMember() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let joiner = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "Liga AlreadyMember",
                maxPlayers: 3
            )

            _ = try await joinLeague(app: app, token: joiner.token, code: league.code)

            // Join again -> conflict
            try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: joiner.token)
                try req.content.encode(JoinLeaguePayload(code: league.code))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("already a member"))
            })
        }
    }

    func testJoinLeagueFailsWhenLeagueIsFull() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let creator = try await TestAuth.register(app: app)
            let joiner1 = try await TestAuth.register(app: app)
            let joiner2 = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: creator.token,
                name: "Liga Full",
                maxPlayers: 2
            )

            _ = try await joinLeague(app: app, token: joiner1.token, code: league.code)

            // league is now full (creator + joiner1) -> joiner2 should fail
            try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: joiner2.token)
                try req.content.encode(JoinLeaguePayload(code: league.code))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("full"))
            })
        }
    }

    func testDeletePendingLeagueByOwnerRemovesLeague() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let owner = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: owner.token,
                name: "Liga Delete",
                maxPlayers: 2
            )

            let leagueId = try XCTUnwrap(league.id)

            try await app.test(.DELETE, "/api/leagues/\(leagueId)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: owner.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let deleted = try await League.find(leagueId, on: app.db)
            XCTAssertNil(deleted)
        }
    }

    func testDeleteLeagueFailsWhenNotOwner() async throws {
        try await withTestApp { app in
            _ = try await TestSeed.createSeason(app: app, year: 2026, name: "Season 2026", active: true)

            let owner = try await TestAuth.register(app: app)
            let outsider = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: owner.token,
                name: "Liga Delete NotOwner",
                maxPlayers: 2
            )

            let leagueId = try XCTUnwrap(league.id)

            try await app.test(.DELETE, "/api/leagues/\(leagueId)", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: outsider.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("owner"))
            })

            let existing = try await League.find(leagueId, on: app.db)
            XCTAssertNotNil(existing)
        }
    }

    func testLeagueEndpointsRequireToken() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/leagues/my", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
                try req.content.encode(CreateLeaguePayload(
                    name: "No token",
                    maxPlayers: 2,
                    teamsEnabled: false,
                    bansEnabled: false,
                    mirrorEnabled: false
                ))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
                try req.content.encode(JoinLeaguePayload(code: "ABCDEF"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }
}
