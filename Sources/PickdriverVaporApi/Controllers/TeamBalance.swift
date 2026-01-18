//
//  TeamBalance.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 18.01.26.
//

import Vapor
import Fluent
import SQLKit

enum TeamBalance {
    static let minTeamSize = 2
    static let minTeams = 2

    static func requireLeagueFull(_ req: Request, league: League) async throws -> Int {
        let memberCount = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == league.requireID())
            .count()

        guard memberCount == league.maxPlayers else {
            throw Abort(.badRequest, reason: "League must be full to manage teams.")
        }

        return memberCount
    }

    static func maxTeams(for req: Request, league: League, totalPlayers: Int) async throws -> Int {
        let maxTeamsByPlayers = totalPlayers / minTeamSize
        guard maxTeamsByPlayers >= minTeams else {
            throw Abort(.badRequest, reason: "Not enough players to form teams.")
        }

        let sql = req.db as! (any SQLDatabase)
        struct Row: Decodable { let count: Int }

        let row = try await sql.raw("""
            SELECT COUNT(*)::int AS count
            FROM f1_teams
            WHERE season_id = \(bind: league.seasonID)
        """).first(decoding: Row.self)

        let seasonTeams = row?.count ?? 0
        let maxTeamsBySeason = seasonTeams >= minTeams ? seasonTeams : maxTeamsByPlayers

        return min(maxTeamsBySeason, maxTeamsByPlayers)
    }

    static func teamSizes(for req: Request, leagueID: Int) async throws -> [(teamID: Int, size: Int)] {
        let teams = try await LeagueTeam.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$members)
            .all()

        return try teams.map { team in
            let id = try team.requireID()
            return (teamID: id, size: team.members.count)
        }
    }

    static func validate(totalPlayers: Int, teamSizes: [Int], maxTeams: Int) throws {
        guard isFeasible(totalPlayers: totalPlayers, teamSizes: teamSizes, maxTeams: maxTeams) else {
            throw Abort(.badRequest, reason: "Team distribution is not balanced or possible.")
        }
    }

    static func isFeasible(totalPlayers: Int, teamSizes: [Int], maxTeams: Int) -> Bool {
        let assigned = teamSizes.reduce(0, +)
        guard assigned <= totalPlayers else { return false }
        guard teamSizes.allSatisfy({ $0 >= minTeamSize }) else { return false }

        let remaining = totalPlayers - assigned
        let currentTeams = teamSizes.count

        for k in minTeams...maxTeams {
            guard k >= currentTeams else { continue }

            let minSize = totalPlayers / k
            let maxSize = (totalPlayers + k - 1) / k
            guard minSize >= minTeamSize else { continue }

            if teamSizes.contains(where: { $0 > maxSize }) { continue }

            let minRequired = teamSizes.reduce(0) { $0 + max(0, minSize - $1) } + (k - currentTeams) * minSize
            let maxCapacity = teamSizes.reduce(0) { $0 + (maxSize - $1) } + (k - currentTeams) * maxSize

            if remaining >= minRequired && remaining <= maxCapacity {
                return true
            }
        }

        return false
    }
}
