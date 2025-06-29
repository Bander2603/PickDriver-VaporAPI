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
            WITH latest_team_per_driver AS (
                SELECT DISTINCT ON (rr.driver_id)
                    rr.driver_id,
                    rr.f1_team_id,
                    t.name AS team_name,
                    t.color AS team_color
                FROM race_results rr
                JOIN f1_teams t ON rr.f1_team_id = t.id
                JOIN races r ON rr.race_id = r.id
                WHERE r.completed = true
                ORDER BY rr.driver_id, r.round DESC
            ),
            driver_points AS (
                SELECT
                    rr.driver_id,
                    SUM(rr.points + COALESCE(rr.sprint_points, 0)) AS points
                FROM race_results rr
                JOIN races r ON rr.race_id = r.id
                WHERE r.completed = true
                GROUP BY rr.driver_id
            )
            SELECT
                d.id AS driver_id,
                d.first_name,
                d.last_name,
                d.driver_code,
                dp.points,
                ltpd.f1_team_id AS team_id,
                ltpd.team_name,
                ltpd.team_color
            FROM drivers d
            JOIN driver_points dp ON dp.driver_id = d.id
            JOIN latest_team_per_driver ltpd ON ltpd.driver_id = d.id
            ORDER BY dp.points DESC
        """).all(decoding: DriverStanding.self)
    }


    func getTeamStandings(_ req: Request) async throws -> [TeamStanding] {
        let sql = req.db as! any SQLDatabase
        return try await sql.raw("""
            SELECT 
                t.id AS team_id,
                t.name,
                t.color,
                COALESCE(SUM(rr.points + COALESCE(rr.sprint_points, 0)), 0) AS points
            FROM race_results rr
            JOIN f1_teams t ON rr.f1_team_id = t.id
            GROUP BY t.id, t.name, t.color
            ORDER BY points DESC
        """).all(decoding: TeamStanding.self)
    }
}
