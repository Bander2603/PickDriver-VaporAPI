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

        print("🟢 [AUTH] Bearer token received")

        // 1) Verify JWT ONLY (and only catch JWT verification errors)
        let payload: UserPayload
        do {
            payload = try request.jwt.verify(bearer.token, as: UserPayload.self)
            print("✅ [AUTH] Verified payload: \(payload)")
        } catch {
            print("❌ [AUTH] JWT verification failed: \(String(reflecting: error))")
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        // 2) Load user
        let userId = payload.id
        print("🔎 [AUTH] Trying to find user ID: \(userId)")

        guard let user = try await User.find(userId, on: request.db) else {
            print("❌ [AUTH] User ID \(userId) not found in database")
            throw Abort(.unauthorized, reason: "User not found")
        }

        request.auth.login(user)
        print("🔓 [AUTH] Logged in user ID: \(userId)")

        // 3) IMPORTANT: Do NOT wrap this in the JWT catch
        // Let downstream Abort(.badRequest/.unauthorized/...) pass through unchanged
        return try await next.respond(to: request)
    }
}
