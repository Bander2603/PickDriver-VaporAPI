//
//  RaceController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 14.06.25.
//

import Vapor
import Fluent
import SQLKit

struct RaceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let races = routes.grouped("races")
        races.get(use: getAllHandler)
        races.get("upcoming", use: getUpcomingHandler)
        races.get("current", use: getCurrentHandler)
        races.get(":raceID", use: getByIDHandler)

        let protected = routes.grouped(UserAuthenticator())
        protected.post("races", ":raceID", "results", "publish", use: publishResults)
    }

    struct PublishResultsResponse: Content {
        let createdNotifications: Int
    }

    func getAllHandler(_ req: Request) async throws -> [Race] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        return try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .sort(\.$round)
            .all()
    }

    func getUpcomingHandler(_ req: Request) async throws -> [Race] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        return try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .filter(\.$raceTime > Date())
            .sort(\.$raceTime)
            .all()
    }

    func getCurrentHandler(_ req: Request) async throws -> Race {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        guard let race = try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .filter(\.$completed == false)
            .filter(\.$raceTime > Date())
            .sort(\.$raceTime)
            .first() else {
            throw Abort(.notFound, reason: "No upcoming race found.")
        }
        return race
    }

    func getByIDHandler(_ req: Request) async throws -> Race {
        guard let race = try await Race.find(req.parameters.get("raceID"), on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }
        return race
    }

    func publishResults(_ req: Request) async throws -> PublishResultsResponse {
        _ = try req.auth.require(User.self)

        guard let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid race ID.")
        }

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required.")
        }

        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
            SELECT COUNT(*)::int AS count
            FROM race_results
            WHERE race_id = \(bind: raceID)
        """).first(decoding: CountRow.self)

        guard (row?.count ?? 0) > 0 else {
            throw Abort(.badRequest, reason: "No results found for this race.")
        }

        if !race.completed {
            race.completed = true
            try await race.save(on: req.db)
        }

        let created = try await NotificationService.notifyRaceResults(
            on: req.db,
            app: req.application,
            raceID: raceID
        )
        return PublishResultsResponse(createdNotifications: created)
    }
}
