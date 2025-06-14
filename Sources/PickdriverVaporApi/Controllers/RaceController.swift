//
//  RaceController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 14.06.25.
//

import Vapor
import Fluent

struct RaceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let races = routes.grouped("races")
        races.get(use: getAllHandler)
        races.get("upcoming", use: getUpcomingHandler)
        races.get("current", use: getCurrentHandler)
        races.get(":raceID", use: getByIDHandler)
    }

    func getAllHandler(_ req: Request) async throws -> [Race] {
        try await Race.query(on: req.db).sort(\.$round).all()
    }

    func getUpcomingHandler(_ req: Request) async throws -> [Race] {
        try await Race.query(on: req.db)
            .filter(\.$raceTime > Date())
            .sort(\.$raceTime)
            .all()
    }

    func getCurrentHandler(_ req: Request) async throws -> Race {
        guard let race = try await Race.query(on: req.db)
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
}

