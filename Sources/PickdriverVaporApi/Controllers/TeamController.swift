//
//  TeamController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 18.06.25.
//

import Vapor
import Fluent

struct TeamController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(UserAuthenticator())
        protected.post("teams", ":teamID", "assign", use: assignUserToTeam)
    }
    
    func createTeam(_ req: Request) async throws -> LeagueTeam {
        _ = try req.auth.require(User.self)
        struct Input: Content { let leagueID: Int; let name: String }
        let data = try req.content.decode(Input.self)
        
        guard let league = try await League.find(data.leagueID, on: req.db),
              league.status == "pending",
              league.teamsEnabled else {
            throw Abort(.badRequest, reason: "Team creation not allowed.")
        }
        
        let memberCount = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == data.leagueID)
            .count()
        
        let teamCount = try await LeagueTeam.query(on: req.db)
            .filter(\.$league.$id == data.leagueID)
            .count()
        
        guard teamCount < memberCount / 2 else {
            throw Abort(.badRequest, reason: "Too many teams already.")
        }
        
        let team = LeagueTeam(name: data.name, leagueID: data.leagueID)
        try await team.save(on: req.db)
        return team
    }
    
    func updateTeam(_ req: Request) async throws -> LeagueTeam {
        _ = try req.auth.require(User.self)
        struct Input: Content { let name: String }
        let data = try req.content.decode(Input.self)
        
        guard let team = try await LeagueTeam.find(req.parameters.get("teamID"), on: req.db),
              let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending" else {
            throw Abort(.badRequest, reason: "Cannot edit team.")
        }
        
        team.name = data.name
        try await team.save(on: req.db)
        return team
    }
    
    func deleteTeam(_ req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self)
        
        guard let team = try await LeagueTeam.find(req.parameters.get("teamID"), on: req.db),
              let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending" else {
            throw Abort(.badRequest, reason: "Cannot delete team.")
        }
        
        let memberCount = try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == team.requireID())
            .count()
        
        if memberCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete team with members.")
        }
        
        try await team.delete(on: req.db)
        return .ok
    }
    
    func assignUserToTeam(_ req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self)
        guard let teamID = req.parameters.get("teamID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID")
        }
        
        struct Input: Content {
            let userID: Int
        }
        let data = try req.content.decode(Input.self)
        
        // Fetch team
        guard let team = try await LeagueTeam.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found")
        }
        
        // Fetch league
        let league = try await League.find(team.$league.id, on: req.db)
        guard let league = league, league.status == "pending", league.teamsEnabled else {
            throw Abort(.badRequest, reason: "Team assignment not allowed in this league")
        }
        
        // Check if user is a member of the league
        let memberExists = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == data.userID)
            .filter(\.$league.$id == league.requireID())
            .first() != nil
        
        guard memberExists else {
            throw Abort(.badRequest, reason: "User is not a member of this league")
        }
        
        // Check if user already has a team in this league
        let existingTeam = try await TeamMember.query(on: req.db)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == league.requireID())
            .filter(TeamMember.self, \TeamMember.$user.$id == data.userID)
            .first()
        
        if existingTeam != nil {
            throw Abort(.conflict, reason: "User is already assigned to a team in this league")
        }
        
        // Check team capacity
        let currentMembers = try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == team.requireID())
            .count()
        
        let maxPerTeam = league.maxPlayers / 2
        guard currentMembers < maxPerTeam else {
            throw Abort(.conflict, reason: "Team is already full")
        }
        
        let assignment = TeamMember(userID: data.userID, teamID: try team.requireID())
        try await assignment.save(on: req.db)
        
        return .ok
    }
}
