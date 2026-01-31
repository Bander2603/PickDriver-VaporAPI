//
//  Season+Active.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 31.01.26.
//

import Vapor
import Fluent

extension Season {
    static func requireActive(on db: any Database) async throws -> Season {
        guard let season = try await Season.query(on: db)
            .filter(\.$active == true)
            .first()
        else {
            throw Abort(.badRequest, reason: "No active season found.")
        }

        return season
    }

    static func requireActiveID(on db: any Database) async throws -> Int {
        let season = try await requireActive(on: db)
        return try season.requireID()
    }
}
