//
//  PlayerController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 29.06.25.
//

import Vapor
import Fluent
import SQLKit

struct PlayerStanding: Content {
    let user_id: Int
    let username: String
    let total_points: Double
    let team_id: Int?
    let total_deviation: Double
}

struct PlayerTeamStanding: Content {
    let team_id: Int
    let name: String
    let total_points: Double
    let total_deviation: Double
}

struct PickHistory: Content {
    let race_name: String
    let round: Int
    let pick_position: Int
    let driver_name: String
    let points: Double
    let expected_points: Double?
    let deviation: Double?
}

struct PlayerController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(UserAuthenticator())
        protected.get("standings", "players", use: getPlayerStandings)
        protected.get("standings", "teams", use: getTeamStandings)
        protected.get("standings", "picks", use: getPickHistory)
    }

    func getPlayerStandings(_ req: Request) async throws -> [PlayerStanding] {
        let sql = req.db as! (any SQLDatabase)

        let _ = try req.auth.require(User.self)
        guard let leagueID = req.query[Int.self, at: "league_id"] else {
            throw Abort(.badRequest, reason: "Missing league_id parameter")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        return try await sql.raw("""
            WITH picks AS (
                SELECT
                    pp.user_id,
                    CASE
                        WHEN pp.is_autopick THEN rr.points::double precision * 0.5
                        ELSE rr.points::double precision
                    END AS points,
                    rd.pick_order,
                    pp.draft_id,
                    pp.is_mirror_pick
                FROM player_picks pp
                JOIN race_drafts rd ON pp.draft_id = rd.id
                JOIN races r ON rd.race_id = r.id
                JOIN race_results rr ON rr.driver_id = pp.driver_id AND rr.race_id = r.id
                WHERE r.completed = true
                  AND pp.is_banned = false
                  AND rd.league_id = \(bind: leagueID)
            ),
            pick_positions AS (
                SELECT
                    p.user_id,
                    p.points,
                    p.is_mirror_pick,
                    idx.pick_index + 1 AS pick_position
                FROM picks p
                JOIN LATERAL (
                    SELECT
                        pos - 1 AS pick_index,
                        (
                            SELECT COUNT(*) 
                            FROM UNNEST(p.pick_order) WITH ORDINALITY AS t2(u2, p2)
                            WHERE p2 < pos AND u2 = u_id
                        ) > 0 AS is_mirror
                    FROM UNNEST(p.pick_order) WITH ORDINALITY AS t(u_id, pos)
                    WHERE u_id = p.user_id
                ) idx ON idx.is_mirror = p.is_mirror_pick
            ),
            expected AS (
                SELECT * FROM (VALUES
                    (1, 25.0), (2, 18.0), (3, 15.0), (4, 12.0), (5, 10.0),
                    (6, 8.0), (7, 6.0), (8, 4.0), (9, 2.0), (10, 1.0)
                ) AS t(pick_position, expected_points)
            ),
            league_team_members AS (
                SELECT tm.user_id, tm.team_id
                FROM team_members tm
                JOIN league_teams lt ON tm.team_id = lt.id
                WHERE lt.league_id = \(bind: leagueID)
            )
            SELECT
                u.id AS user_id,
                u.username,
                COALESCE(SUM(pp.points), 0.0) AS total_points,
                COALESCE(SUM(pp.points - COALESCE(e.expected_points, 0.0)), 0.0) AS total_deviation,
                ltm.team_id
            FROM pick_positions pp
            JOIN users u ON pp.user_id = u.id
            LEFT JOIN expected e ON e.pick_position = pp.pick_position
            LEFT JOIN league_team_members ltm ON u.id = ltm.user_id
            GROUP BY u.id, u.username, ltm.team_id
            ORDER BY total_points DESC;
        """).all(decoding: PlayerStanding.self)
    }

    func getTeamStandings(_ req: Request) async throws -> [PlayerTeamStanding] {
        let sql = req.db as! (any SQLDatabase)

        let _ = try req.auth.require(User.self)
        guard let leagueID = req.query[Int.self, at: "league_id"] else {
            throw Abort(.badRequest, reason: "Missing league_id parameter")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        return try await sql.raw("""
            WITH picks AS (
                SELECT
                    pp.user_id,
                    CASE
                        WHEN pp.is_autopick THEN rr.points::double precision * 0.5
                        ELSE rr.points::double precision
                    END AS points,
                    rd.pick_order,
                    pp.draft_id,
                    pp.is_mirror_pick
                FROM player_picks pp
                JOIN race_drafts rd ON pp.draft_id = rd.id
                JOIN races r ON rd.race_id = r.id
                JOIN race_results rr ON rr.driver_id = pp.driver_id AND rr.race_id = r.id
                WHERE r.completed = true
                  AND pp.is_banned = false
                  AND rd.league_id = \(bind: leagueID)
            ),
            pick_positions AS (
                SELECT
                    p.user_id,
                    p.points,
                    p.is_mirror_pick,
                    idx.pick_index + 1 AS pick_position
                FROM picks p
                JOIN LATERAL (
                    SELECT
                        pos - 1 AS pick_index,
                        (
                            SELECT COUNT(*) 
                            FROM UNNEST(p.pick_order) WITH ORDINALITY AS t2(u2, p2)
                            WHERE p2 < pos AND u2 = u_id
                        ) > 0 AS is_mirror
                    FROM UNNEST(p.pick_order) WITH ORDINALITY AS t(u_id, pos)
                    WHERE u_id = p.user_id
                ) idx ON idx.is_mirror = p.is_mirror_pick
            ),
            expected AS (
                SELECT * FROM (VALUES
                    (1, 25.0), (2, 18.0), (3, 15.0), (4, 12.0), (5, 10.0),
                    (6, 8.0), (7, 6.0), (8, 4.0), (9, 2.0), (10, 1.0)
                ) AS t(pick_position, expected_points)
            ),
            league_team_members AS (
                SELECT tm.user_id, tm.team_id
                FROM team_members tm
                JOIN league_teams lt ON tm.team_id = lt.id
                WHERE lt.league_id = \(bind: leagueID)
            )
            SELECT
                t.id AS team_id,
                t.name,
                COALESCE(SUM(pp.points), 0.0) AS total_points,
                COALESCE(SUM(pp.points - COALESCE(e.expected_points, 0.0)), 0.0) AS total_deviation
            FROM pick_positions pp
            JOIN league_team_members ltm ON pp.user_id = ltm.user_id
            JOIN league_teams t ON ltm.team_id = t.id
            LEFT JOIN expected e ON e.pick_position = pp.pick_position
            GROUP BY t.id, t.name
            ORDER BY total_points DESC;
        """).all(decoding: PlayerTeamStanding.self)
    }
    
    func getPickHistory(_ req: Request) async throws -> [PickHistory] {
        let sql = req.db as! (any SQLDatabase)

        let _ = try req.auth.require(User.self)
        guard let leagueID = req.query[Int.self, at: "league_id"],
              let userID = req.query[Int.self, at: "user_id"] else {
            throw Abort(.badRequest, reason: "Missing league_id or user_id parameter")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        let targetMembership = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$user.$id == userID)
            .first()

        guard targetMembership != nil else {
            throw Abort(.forbidden, reason: "User is not a member of this league")
        }

        return try await sql.raw("""
            WITH user_drafts AS (
                SELECT
                    rd.race_id,
                    r.name AS race_name,
                    r.round,
                    rd.pick_order,
                    rd.id AS draft_id
                FROM race_drafts rd
                JOIN races r ON rd.race_id = r.id
                WHERE rd.league_id = \(bind: leagueID)
                  AND r.completed = true
            ),
            user_pick_positions AS (
                SELECT
                    ud.race_id,
                    ud.race_name,
                    ud.round,
                    ud.draft_id,
                    pos AS pick_position,
                    p_uid AS user_id,
                    (
                        SELECT COUNT(*) 
                        FROM UNNEST(ud.pick_order) WITH ORDINALITY AS t2(u2, p2)
                        WHERE p2 < pos AND u2 = p_uid
                    ) > 0 AS is_mirror
                FROM user_drafts ud,
                UNNEST(ud.pick_order) WITH ORDINALITY AS t(p_uid, pos)
                WHERE p_uid = \(bind: userID)
            ),
            expected_points AS (
                SELECT * FROM (VALUES
                    (1, 25.0), (2, 18.0), (3, 15.0), (4, 12.0), (5, 10.0),
                    (6, 8.0), (7, 6.0), (8, 4.0), (9, 2.0), (10, 1.0)
                ) AS t(pick_position, expected_points)
            ),
            picks_with_points AS (
                SELECT
                    upp.race_name,
                    upp.round,
                    upp.pick_position,
                    d.first_name || ' ' || d.last_name AS driver_name,
                    CASE
                        WHEN pp.is_autopick THEN rr.points::double precision * 0.5
                        ELSE rr.points::double precision
                    END AS points
                FROM user_pick_positions upp
                LEFT JOIN LATERAL (
                    SELECT *
                    FROM player_picks ppx
                    WHERE ppx.draft_id = upp.draft_id
                      AND ppx.user_id = upp.user_id
                      AND ppx.is_mirror_pick = upp.is_mirror
                    ORDER BY ppx.picked_at DESC
                    LIMIT 1
                ) pp ON true
                LEFT JOIN drivers d ON d.id = pp.driver_id
                LEFT JOIN race_results rr ON rr.driver_id = d.id AND rr.race_id = upp.race_id
                WHERE pp.id IS NULL OR pp.is_banned IS DISTINCT FROM true
            )
            SELECT
                pwp.race_name,
                pwp.round,
                pwp.pick_position,
                COALESCE(pwp.driver_name, 'Missed Pick') AS driver_name,
                COALESCE(pwp.points, 0.0) AS points,
                ep.expected_points,
                COALESCE(pwp.points, 0.0) - ep.expected_points AS deviation
            FROM picks_with_points pwp
            LEFT JOIN expected_points ep ON pwp.pick_position = ep.pick_position
            ORDER BY pwp.round, pwp.pick_position;
        """).all(decoding: PickHistory.self)
    }

}
