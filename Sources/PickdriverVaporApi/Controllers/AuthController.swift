//
//  AuthController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.06.25.
//

import Vapor
import Fluent
import JWT

struct UserPayload: JWTPayload {
    var id: Int
    var exp: ExpirationClaim

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }
}

struct RegisterRequest: Content {
    let username: String
    let email: String
    let password: String
}

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct AuthResponse: Content {
    let user: User.Public
    let token: String
}

final class AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")
        auth.post("register", use: registerHandler)
        auth.post("login", use: loginHandler)
        
        // 🔐 Protected route group
        let protected = auth.grouped(UserAuthenticator())
        protected.get("profile", use: profileHandler)
    }

    func registerHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(RegisterRequest.self)

        guard data.username.count >= 3 else {
            throw Abort(.badRequest, reason: "Username must be at least 3 characters long.")
        }
        guard data.password.count >= 6 else {
            throw Abort(.badRequest, reason: "Password must be at least 6 characters long.")
        }

        // Check for existing email or username
        if try await User.query(on: req.db).filter(\.$email == data.email).first() != nil {
            throw Abort(.conflict, reason: "Email already in use.")
        }
        if try await User.query(on: req.db).filter(\.$username == data.username).first() != nil {
            throw Abort(.conflict, reason: "Username already in use.")
        }

        let hash = try Bcrypt.hash(data.password)
        let user = User(username: data.username, email: data.email, passwordHash: hash)
        try await user.save(on: req.db)

        let token = try generateToken(for: user, on: req)

        return AuthResponse(user: user.convertToPublic(), token: token)
    }

    func loginHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(LoginRequest.self)

        guard let user = try await User.query(on: req.db).filter(\.$email == data.email).first() else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        guard try Bcrypt.verify(data.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        let token = try generateToken(for: user, on: req)

        return AuthResponse(user: user.convertToPublic(), token: token)
    }
    
    func profileHandler(_ req: Request) throws -> User.Public {
        let user = try req.auth.require(User.self)
        return user.convertToPublic()
    }

    private func generateToken(for user: User, on req: Request) throws -> String {
        let expiration = ExpirationClaim(value: .init(timeIntervalSinceNow: req.application.jwtExpiration))
        let payload = UserPayload(id: try user.requireID(), exp: expiration)
        return try req.jwt.sign(payload)
    }
}
