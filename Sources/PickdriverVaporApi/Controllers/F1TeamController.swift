//
//  F1TeamController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 31.01.26.
//

import Vapor
import Fluent

struct F1TeamController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let f1 = routes.grouped("f1")
        f1.get("teams", use: getAllHandler)
    }

    func getAllHandler(_ req: Request) async throws -> [F1Team] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        return try await F1Team.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .all()
    }
}
