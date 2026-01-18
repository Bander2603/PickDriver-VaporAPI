//
//  LeagueAccess.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import Vapor
import Fluent

enum LeagueAccess {
    static func requireMember(_ req: Request, leagueID: Int) async throws -> League {
        let user = try req.auth.require(User.self)

        guard let league = try await League.find(leagueID, on: req.db) else {
            throw Abort(.notFound, reason: "League not found")
        }

        let isMember = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$user.$id == user.requireID())
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "You are not a member of this league")
        }

        return league
    }

    static func requireMember(_ req: Request, league: League) async throws {
        let user = try req.auth.require(User.self)
        let leagueID = try league.requireID()

        let isMember = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$user.$id == user.requireID())
            .first() != nil

        guard isMember else {
            throw Abort(.forbidden, reason: "You are not a member of this league")
        }
    }

    static func requireOwner(_ req: Request, league: League) throws {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard league.$creator.id == userID else {
            throw Abort(.forbidden, reason: "Only the league owner can perform this action")
        }
    }
}
