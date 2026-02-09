//
//  InternalServiceAuthenticator.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 07.02.26.
//

import Vapor

struct InternalServiceAuthenticator: AsyncMiddleware {
    private static let headerName = "X-Internal-Token"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let expected = request.application.internalServiceToken, !expected.isEmpty else {
            request.logger.error("Internal auth misconfigured: missing INTERNAL_SERVICE_TOKEN")
            throw Abort(.internalServerError, reason: "Internal service authentication is not configured.")
        }

        guard let received = request.headers.first(name: Self.headerName),
              !received.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.unauthorized, reason: "Missing internal service token.")
        }

        guard received == expected else {
            throw Abort(.unauthorized, reason: "Invalid internal service token.")
        }

        return try await next.respond(to: request)
    }
}
