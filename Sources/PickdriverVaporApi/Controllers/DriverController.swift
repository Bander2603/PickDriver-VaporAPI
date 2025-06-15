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
        try await Driver.query(on: req.db).all()
    }
}
