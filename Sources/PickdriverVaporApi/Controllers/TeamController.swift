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

        let league = try await LeagueAccess.requireMember(req, leagueID: data.leagueID)

        guard league.status == "pending",
              league.teamsEnabled else {
            print("❌ Invalid league or conditions not met for team creation.")
            throw Abort(.badRequest, reason: "Team creation not allowed.")
        }

        let memberCount = try await TeamBalance.requireLeagueFull(req, league: league)
        let maxTeams = try await TeamBalance.maxTeams(for: req, league: league, totalPlayers: memberCount)

        guard let userIDs = data.userIDs, !userIDs.isEmpty else {
            throw Abort(.badRequest, reason: "A team must have at least 2 players.")
        }

        let requestedUserIDs = Array(Set(userIDs))
        guard requestedUserIDs.count == userIDs.count else {
            throw Abort(.badRequest, reason: "Duplicate user IDs are not allowed.")
        }

        guard requestedUserIDs.count >= TeamBalance.minTeamSize else {
            throw Abort(.badRequest, reason: "A team must have at least 2 players.")
        }

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == data.leagueID)
            .all()
        let memberIDs = Set(members.map { $0.$user.id })

        guard requestedUserIDs.allSatisfy(memberIDs.contains) else {
            throw Abort(.badRequest, reason: "All users must be members of the league.")
        }

        let assigned = try await TeamMember.query(on: req.db)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == data.leagueID)
            .all()
        let assignedUserIDs = Set(assigned.map { $0.$user.id })

        if requestedUserIDs.contains(where: { assignedUserIDs.contains($0) }) {
            throw Abort(.conflict, reason: "One or more users are already assigned to a team in this league.")
        }

        let currentTeamSizes = try await TeamBalance.teamSizes(for: req, leagueID: data.leagueID)
        let prospectiveSizes = currentTeamSizes.map { $0.size } + [requestedUserIDs.count]
        try TeamBalance.validate(totalPlayers: memberCount, teamSizes: prospectiveSizes, maxTeams: maxTeams)

        let team = LeagueTeam(name: data.name, leagueID: data.leagueID)
        try await team.save(on: req.db)

        for userID in requestedUserIDs {
            let assignment = TeamMember(userID: userID, teamID: try team.requireID())
            try await assignment.save(on: req.db)
        }

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

        struct Input: Content {
            let name: String
            let userIDs: [Int]?

            enum CodingKeys: String, CodingKey {
                case name
                case userIDs = "user_ids"
            }
        }

        let data = try req.content.decode(Input.self)
        print("📝 Update team data: \(data)")

        guard let team = try await LeagueTeam.find(req.parameters.get("teamID"), on: req.db),
              let league = try await League.find(team.$league.id, on: req.db),
              league.status == "pending" else {
            print("❌ Cannot edit team or league conditions not met.")
            throw Abort(.badRequest, reason: "Cannot edit team.")
        }

        try await LeagueAccess.requireMember(req, league: league)

        let memberCount = try await TeamBalance.requireLeagueFull(req, league: league)
        let maxTeams = try await TeamBalance.maxTeams(for: req, league: league, totalPlayers: memberCount)

        guard let userIDs = data.userIDs, !userIDs.isEmpty else {
            throw Abort(.badRequest, reason: "A team must have at least 2 players.")
        }

        let requestedUserIDs = Array(Set(userIDs))
        guard requestedUserIDs.count == userIDs.count else {
            throw Abort(.badRequest, reason: "Duplicate user IDs are not allowed.")
        }

        guard requestedUserIDs.count >= TeamBalance.minTeamSize else {
            throw Abort(.badRequest, reason: "A team must have at least 2 players.")
        }

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == league.requireID())
            .all()
        let memberIDs = Set(members.map { $0.$user.id })

        guard requestedUserIDs.allSatisfy(memberIDs.contains) else {
            throw Abort(.badRequest, reason: "All users must be members of the league.")
        }

        let teamID = try team.requireID()
        let assigned = try await TeamMember.query(on: req.db)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == league.requireID())
            .all()

        let assignedUserIDs = Set(assigned.map { $0.$user.id })
        let currentTeamUserIDs = Set(assigned.filter { $0.$team.id == teamID }.map { $0.$user.id })
        let otherTeamUserIDs = assignedUserIDs.subtracting(currentTeamUserIDs)

        if requestedUserIDs.contains(where: { otherTeamUserIDs.contains($0) }) {
            throw Abort(.conflict, reason: "One or more users are already assigned to another team in this league.")
        }

        let currentTeamSizes = try await TeamBalance.teamSizes(for: req, leagueID: league.requireID())
        var prospectiveSizes: [Int] = []
        var replaced = false

        for (id, size) in currentTeamSizes {
            if id == teamID {
                prospectiveSizes.append(requestedUserIDs.count)
                replaced = true
            } else {
                prospectiveSizes.append(size)
            }
        }

        guard replaced else {
            throw Abort(.internalServerError, reason: "Team not found in league.")
        }

        try TeamBalance.validate(totalPlayers: memberCount, teamSizes: prospectiveSizes, maxTeams: maxTeams)

        team.name = data.name
        try await team.save(on: req.db)

        try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == teamID)
            .delete()

        for userID in requestedUserIDs {
            let assignment = TeamMember(userID: userID, teamID: teamID)
            try await assignment.save(on: req.db)
        }

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

        try await LeagueAccess.requireMember(req, league: league)

        let memberCount = try await TeamBalance.requireLeagueFull(req, league: league)
        let maxTeams = try await TeamBalance.maxTeams(for: req, league: league, totalPlayers: memberCount)

        let leagueID = try league.requireID()
        let teamID = try team.requireID()
        let currentTeamSizes = try await TeamBalance.teamSizes(for: req, leagueID: leagueID)
        let filteredSizes = currentTeamSizes.filter { $0.teamID != teamID }.map { $0.size }
        try TeamBalance.validate(totalPlayers: memberCount, teamSizes: filteredSizes, maxTeams: maxTeams)

        // Remove team members
        let members = try await TeamMember.query(on: req.db)
            .filter(\.$team.$id == teamID)
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

        try await LeagueAccess.requireMember(req, league: league)

        let existingTeam = try await TeamMember.query(on: req.db)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == league.requireID())
            .filter(TeamMember.self, \TeamMember.$user.$id == data.userID)
            .first()

        if existingTeam != nil {
            throw Abort(.conflict, reason: "User is already assigned to a team in this league")
        }

        let memberCount = try await TeamBalance.requireLeagueFull(req, league: league)
        let maxTeams = try await TeamBalance.maxTeams(for: req, league: league, totalPlayers: memberCount)

        let memberExists = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == data.userID)
            .filter(\.$league.$id == league.requireID())
            .first() != nil

        guard memberExists else {
            throw Abort(.badRequest, reason: "User is not a member of this league")
        }

        let currentTeamSizes = try await TeamBalance.teamSizes(for: req, leagueID: league.requireID())
        let targetTeamID = try team.requireID()

        var prospectiveSizes: [Int] = []
        var found = false

        for (id, size) in currentTeamSizes {
            if id == targetTeamID {
                prospectiveSizes.append(size + 1)
                found = true
            } else {
                prospectiveSizes.append(size)
            }
        }

        guard found else {
            throw Abort(.internalServerError, reason: "Team not found in league.")
        }

        try TeamBalance.validate(totalPlayers: memberCount, teamSizes: prospectiveSizes, maxTeams: maxTeams)

        let assignment = TeamMember(userID: data.userID, teamID: try team.requireID())
        try await assignment.save(on: req.db)
        print("✅ User \(data.userID) assigned to team \(teamID)")
        return .ok
    }
}

