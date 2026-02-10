//
//  InternalHTTPSMiddleware.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 10.02.26.
//

import Vapor

struct InternalHTTPSMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.application.internalRoutesRequireHTTPS else {
            return try await next.respond(to: request)
        }

        guard isHTTPS(request) else {
            throw Abort(.forbidden, reason: "HTTPS is required for internal routes.")
        }

        return try await next.respond(to: request)
    }

    private func isHTTPS(_ request: Request) -> Bool {
        if request.url.scheme?.lowercased() == "https" {
            return true
        }

        if request.headers.first(name: "X-Forwarded-Proto")?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "https" {
            return true
        }

        guard let forwarded = request.headers.first(name: "Forwarded")?.lowercased() else {
            return false
        }
        return forwarded.contains("proto=https")
    }
}
