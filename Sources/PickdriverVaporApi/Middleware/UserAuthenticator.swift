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
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            print("🔴 [AUTH] No bearer token found")
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        do {
            print("🟢 [AUTH] Raw token: \(bearer.token)")
            let payload = try request.jwt.verify(bearer.token, as: UserPayload.self)
            print("✅ [AUTH] Verified payload: \(payload)")

            let userId = payload.id
            print("🔎 [AUTH] Trying to find user ID: \(userId)")
            guard let user = try await User.find(userId, on: request.db) else {
                print("❌ [AUTH] User ID \(userId) not found in database")
                throw Abort(.unauthorized, reason: "User not found")
            }

            request.auth.login(user)
            print("🔓 [AUTH] Logged in user ID: \(userId)")
            return try await next.respond(to: request)

        } catch {
            print("❌ [AUTH] Token verification failed: \(String(reflecting: error))")
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

    }
}
