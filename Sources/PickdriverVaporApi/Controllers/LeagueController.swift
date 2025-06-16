//
//  LeagueController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

struct LeagueController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let leagueRoutes = routes.grouped("api", "leagues")

        let protected = leagueRoutes.grouped(UserAuthenticator())

        protected.get("my", use: getMyLeagues)
        protected.post("create", use: createLeague)
    }

    func getMyLeagues(_ req: Request) async throws -> [League.Public] {
        let user = try req.auth.require(User.self)

        let leagueMemberships = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .with(\.$league)
            .all()

        return leagueMemberships.map { $0.league.convertToPublic() }
    }

    func createLeague(_ req: Request) async throws -> League.Public {
        let user = try req.auth.require(User.self)
        let data = try req.content.decode(CreateLeagueRequest.self)

        let code = generateUniqueCode()

        let league = League(name: data.name, code: code, status: "pending", creatorID: try user.requireID())
        try await league.save(on: req.db)

        let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
        try await member.save(on: req.db)

        return league.convertToPublic()
    }

    private func generateUniqueCode(length: Int = 6) -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }
}

struct CreateLeagueRequest: Content {
    let name: String
}

struct JoinLeagueRequest: Content {
    let code: String
}

func joinLeague(_ req: Request) async throws -> League.Public {
    let user = try req.auth.require(User.self)
    let data = try req.content.decode(JoinLeagueRequest.self)

    // Check if the league with this code exists
    guard let league = try await League.query(on: req.db)
        .filter(\.$code == data.code)
        .first() else {
        throw Abort(.notFound, reason: "League with the given code not found.")
    }

    // Check if user is already a member
    let alreadyMember = try await LeagueMember.query(on: req.db)
        .filter(\.$user.$id == user.requireID())
        .filter(\.$league.$id == league.requireID())
        .first() != nil

    if alreadyMember {
        throw Abort(.conflict, reason: "User is already a member of this league.")
    }

    // Create the membership
    let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
    try await member.save(on: req.db)

    return league.convertToPublic()
}
