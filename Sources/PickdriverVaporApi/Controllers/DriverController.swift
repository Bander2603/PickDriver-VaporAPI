//
//  DriverController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

struct DriverController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let drivers = routes.grouped("drivers")
        drivers.get(use: getAllHandler)
    }

    func getAllHandler(_ req: Request) async throws -> [Driver] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        return try await Driver.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .all()
    }
}
