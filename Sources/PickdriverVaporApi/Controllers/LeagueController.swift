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
        let protected = routes.grouped(UserAuthenticator())

        protected.get("my", use: getMyLeagues)
        protected.post("create", use: createLeague)
        protected.post("join", use: joinLeague)
        
        protected.get(":leagueID", "members", use: getLeagueMembers)
        protected.get(":leagueID", "teams", use: getLeagueTeams)
        protected.post(":leagueID", "assign-pick-order", use: assignPickOrder)
    }

    func getMyLeagues(_ req: Request) async throws -> [League.Public] {
        let user = try req.auth.require(User.self)

        let memberships = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .all()

        let leagueIDs = memberships.map { $0.$league.id }

        let leagues = try await League.query(on: req.db)
            .filter(\.$id ~~ leagueIDs)
            .all()

        return leagues.map { $0.convertToPublic() }
    }

    func createLeague(_ req: Request) async throws -> League.Public {
        let user = try req.auth.require(User.self)
        let data = try req.content.decode(CreateLeagueRequest.self)

        let code = generateUniqueCode()

        guard let season = try await Season.query(on: req.db)
            .filter(\.$active == true)
            .first()
        else {
            throw Abort(.badRequest, reason: "No active season found.")
        }

        let league = League(
            name: data.name,
            code: code,
            status: "pending",
            creatorID: try user.requireID(),
            teamsEnabled: data.teamsEnabled,
            bansEnabled: data.bansEnabled,
            mirrorEnabled: data.mirrorEnabled,
            maxPlayers: data.maxPlayers,
            seasonID: try season.requireID()
        )

        try await league.save(on: req.db)

        let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
        try await member.save(on: req.db)

        return league.convertToPublic()
    }

    func getLeagueMembers(_ req: Request) async throws -> [User.Public] {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$user)
            .all()

        return members.map { $0.user.convertToPublic() }
    }

    func getLeagueTeams(_ req: Request) async throws -> [LeagueTeam] {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        return try await LeagueTeam.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$members)
            .all()
    }

    func assignPickOrder(_ req: Request) async throws -> HTTPStatus {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        var members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .all()

        guard !members.isEmpty else {
            throw Abort(.badRequest, reason: "No members found in this league.")
        }

        members.shuffle()

        for (index, member) in members.enumerated() {
            member.pickOrder = index + 1
            try await member.save(on: req.db)
        }

        return .ok
    }

    private func generateUniqueCode(length: Int = 6) -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }
}

struct CreateLeagueRequest: Content {
    let name: String
    let maxPlayers: Int
    let teamsEnabled: Bool
    let bansEnabled: Bool
    let mirrorEnabled: Bool
}

struct JoinLeagueRequest: Content {
    let code: String
}

func joinLeague(_ req: Request) async throws -> League.Public {
    let user = try req.auth.require(User.self)
    let data = try req.content.decode(JoinLeagueRequest.self)

    guard let league = try await League.query(on: req.db)
        .filter(\.$code == data.code)
        .first() else {
        throw Abort(.notFound, reason: "League with the given code not found.")
    }

    guard league.status.lowercased() == "pending" else {
        throw Abort(.badRequest, reason: "You can only join leagues that are pending.")
    }

    let alreadyMember = try await LeagueMember.query(on: req.db)
        .filter(\.$user.$id == user.requireID())
        .filter(\.$league.$id == league.requireID())
        .first() != nil

    if alreadyMember {
        throw Abort(.conflict, reason: "You are already a member of this league.")
    }

    let memberCount = try await LeagueMember.query(on: req.db)
        .filter(\.$league.$id == league.requireID())
        .count()

    if memberCount >= league.maxPlayers {
        throw Abort(.conflict, reason: "League is already full.")
    }

    let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
    try await member.save(on: req.db)

    return league.convertToPublic()
}
