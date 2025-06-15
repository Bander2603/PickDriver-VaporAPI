//
//  StandingsController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import SQLKit

struct StandingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let standings = routes.grouped("standings")
        standings.get("f1", "drivers", use: getDriverStandings)
        standings.get("f1", "teams", use: getTeamStandings)
    }

    func getDriverStandings(_ req: Request) async throws -> [DriverStanding] {
        let sql = req.db as! any SQLDatabase
        return try await sql.raw("""
            SELECT 
                d.id AS driver_id,
                d.first_name,
                d.last_name,
                d.driver_code,
                COALESCE(SUM(rr.points), 0) AS points,
                t.id AS team_id,
                t.name AS team_name,
                t.color AS team_color
            FROM race_results rr
            JOIN drivers d ON rr.driver_id = d.id
            JOIN f1_teams t ON rr.f1_team_id = t.id
            GROUP BY d.id, d.first_name, d.last_name, d.driver_code, t.id, t.name, t.color
            ORDER BY points DESC
        """).all(decoding: DriverStanding.self)
    }

    func getTeamStandings(_ req: Request) async throws -> [TeamStanding] {
        let sql = req.db as! any SQLDatabase
        return try await sql.raw("""
            SELECT 
                t.id AS team_id,
                t.name,
                t.color,
                COALESCE(SUM(rr.points), 0) AS points
            FROM race_results rr
            JOIN f1_teams t ON rr.f1_team_id = t.id
            GROUP BY t.id, t.name, t.color
            ORDER BY points DESC
        """).all(decoding: TeamStanding.self)
    }
}
