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
            request.logger.warning("Auth: missing bearer token")
            throw Abort(.unauthorized, reason: "Missing Bearer token")
        }

        request.logger.debug("Auth: bearer token received")

        // 1) Verify JWT ONLY (and only catch JWT verification errors)
        let payload: UserPayload
        do {
            payload = try request.jwt.verify(bearer.token, as: UserPayload.self)
            request.logger.debug("Auth: JWT verified")
        } catch {
            request.logger.warning("Auth: JWT verification failed")
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        // 2) Load user
        let userId = payload.id
        request.logger.debug("Auth: loading user for token", metadata: ["user_id": "\(userId)"])

        guard let user = try await User.find(userId, on: request.db) else {
            request.logger.warning("Auth: user not found", metadata: ["user_id": "\(userId)"])
            throw Abort(.unauthorized, reason: "User not found")
        }

        request.auth.login(user)
        request.logger.info("Auth: user authenticated", metadata: ["user_id": "\(userId)"])

        // 3) IMPORTANT: Do NOT wrap this in the JWT catch
        // Let downstream Abort(.badRequest/.unauthorized/...) pass through unchanged
        return try await next.respond(to: request)
    }
}
