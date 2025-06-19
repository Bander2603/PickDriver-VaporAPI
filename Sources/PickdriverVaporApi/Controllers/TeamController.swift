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
        protected.post("teams", use: createTeam)
        protected.put("teams", ":teamID", use: updateTeam)
        protected.delete("teams", ":teamID", use: deleteTeam)
        protected.post("teams", ":teamID", "assign", use: assignUserToTeam)
    }

    func createTeam(_ req: Request) async throws -> LeagueTeam {
        let user = try req.auth.require(User.self)
        print("🟢 Creating team request by user ID: \(try user.requireID())")

        struct Input: Content {
            let leagueID: Int
            let name: String
            let userIDs: [Int]?

            enum CodingKeys: String, CodingKey {
                case leagueID = "league_id"
                case name
                case userIDs = "user_ids"
            }
        }

        let data = try req.content.decode(Input.self)
        print("📝 Received team creation data: \(data)")

        guard let league = try await League.find(data.leagueID, on: req.db),
              league.status == "pending",
              league.teamsEnabled else {
            print("❌ Invalid league or conditions not met for team creation.")
            throw Abort(.badRequest, reason: "Team creation not allowed.")
        }

        let memberCount = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == data.leagueID)
            .count()

        let teamCount = try await LeagueTeam.query(on: req.db)
            .filter(\.$league.$id == data.leagueID)
            .count()

        guard teamCount < memberCount / 2 else {
            print("❌ Too many teams already: \(teamCount) / \(memberCount)")
            throw Abort(.badRequest, reason: "Too many teams already.")
        }

        // Create the team
        let team = LeagueTeam(name: data.name, leagueID: data.leagueID)
        try await team.save(on: req.db)

        // Assign users if provided
        if let userIDs = data.userIDs {
            for userID in userIDs {
                // Validate user is in league
                let isMember = try await LeagueMember.query(on: req.db)
                    .filter(\.$user.$id == userID)
                    .filter(\.$league.$id == data.leagueID)
                    .first() != nil

                guard isMember else {
                    print("⚠️ Skipping user \(userID) – not a league member.")
                    continue
                }

                let existingTeam = try await TeamMember.query(on: req.db)
                    .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                    .filter(LeagueTeam.self, \LeagueTeam.$league.$id == data.leagueID)
                    .filter(TeamMember.self, \TeamMember.$user.$id == userID)
                    .first()

                guard existingTeam == nil else {
                    print("⚠️ Skipping user \(userID) – already in a team.")
                    continue
                }

                let assignment = TeamMember(userID: userID, teamID: try team.requireID())
                try await assignment.save(on: req.db)
                print("✅ Assigned user \(userID) to team \(try team.requireID())")
            }
        }

        // Fetch full team with members
        guard let fullTeam = try await LeagueTeam.query(on: req.db)
            .filter(\.$id == team.id!)
            .with(\.$members)
            .first() else {
                throw Abort(.internalServerError, reason: "Failed to fetch team after creation")
        }

        return fullTeam
    }

    func updateTeam(_ req: Request) async throws -> LeagueTeam {
        let user = try req.auth.require(User.self)
        print("🟡 Updating team request by user ID: \(try user.requireID())")

        struct Input: Content { let name: String }
        let data = try req.content.decode(Input.self)
        print("📝 Update team data: \(data)")

        guard let team = try await LeagueTeam.find(req.parameters.get("teamID"), on: req.db),
              let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending" else {
            print("❌ Cannot edit team or league conditions not met.")
            throw Abort(.badRequest, reason: "Cannot edit team.")
        }

        team.name = data.name
        try await team.save(on: req.db)

        // Fetch team with members
        guard let fullTeam = try await LeagueTeam.query(on: req.db)
            .filter(\.$id == team.id!)
            .with(\.$members)
            .first() else {
                throw Abort(.internalServerError, reason: "Failed to fetch team after update")
        }

        return fullTeam
    }

    func deleteTeam(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        print("🔴 Delete team request by user ID: \(try user.requireID())")

        guard let team = try await LeagueTeam.find(req.parameters.get("teamID"), on: req.db),
              let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending" else {
            print("❌ Cannot delete team. League invalid or not pending.")
            throw Abort(.badRequest, reason: "Cannot delete team.")
        }

        // Remove team members
        let members = try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == team.requireID())
            .all()

        for member in members {
            print("🧹 Removing team member ID: \(member.id ?? -1)")
            try await member.delete(on: req.db)
        }

        try await team.delete(on: req.db)
        print("✅ Team deleted with ID: \(try team.requireID())")

        return .ok
    }

    func assignUserToTeam(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        print("🔵 Assign user to team request by user ID: \(try user.requireID())")

        guard let teamID = req.parameters.get("teamID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid team ID")
        }

        struct Input: Content { let userID: Int }
        let data = try req.content.decode(Input.self)
        print("📝 Assigning user ID \(data.userID) to team ID \(teamID)")

        guard let team = try await LeagueTeam.find(teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found")
        }

        guard let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending",
              league.teamsEnabled else {
            throw Abort(.badRequest, reason: "Team assignment not allowed in this league")
        }

        let memberExists = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == data.userID)
            .filter(\.$league.$id == league.requireID())
            .first() != nil

        guard memberExists else {
            throw Abort(.badRequest, reason: "User is not a member of this league")
        }

        let existingTeam = try await TeamMember.query(on: req.db)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == league.requireID())
            .filter(TeamMember.self, \TeamMember.$user.$id == data.userID)
            .first()

        if existingTeam != nil {
            throw Abort(.conflict, reason: "User is already assigned to a team in this league")
        }

        let currentMembers = try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == team.requireID())
            .count()

        let maxPerTeam = league.maxPlayers / 2
        guard currentMembers < maxPerTeam else {
            throw Abort(.conflict, reason: "Team is already full")
        }

        let assignment = TeamMember(userID: data.userID, teamID: try team.requireID())
        try await assignment.save(on: req.db)
        print("✅ User \(data.userID) assigned to team \(teamID)")
        return .ok
    }
}
