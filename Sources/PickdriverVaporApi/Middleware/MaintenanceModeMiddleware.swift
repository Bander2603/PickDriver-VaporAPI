//
//  MaintenanceModeMiddleware.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 08.02.26.
//

import Vapor

struct MaintenanceModeMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.application.maintenanceMode else {
            return try await next.respond(to: request)
        }

        let path = request.url.path
        if path.hasPrefix("/api/health") || path.hasPrefix("/api/internal/") {
            return try await next.respond(to: request)
        }

        throw Abort(.serviceUnavailable, reason: "Service is in maintenance mode.")
    }
}
