//
//  UserAuthenticator.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 10.06.25.
//

import Vapor
import JWT
import Fluent

struct UserAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        do {
            let payload = try request.jwt.verify(bearer.token, as: UserPayload.self)

            guard let user = try await User.find(payload.id, on: request.db) else {
                throw Abort(.unauthorized, reason: "User not found")
            }

            request.auth.login(user)
            return try await next.respond(to: request)

        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
    }
}
