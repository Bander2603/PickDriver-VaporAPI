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

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")

        auth.post("register", use: Self.registerHandler)
        auth.post("login", use: Self.loginHandler)

        let protected = auth.grouped(UserAuthenticator())
        protected.get("profile", use: Self.profileHandler)
        protected.put("password", use: Self.updatePasswordHandler)
    }

    static func registerHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(RegisterRequest.self)

        guard data.username.count >= 3 else {
            throw Abort(.badRequest, reason: "Username must be at least 3 characters long.")
        }
        guard data.password.count >= 6 else {
            throw Abort(.badRequest, reason: "Password must be at least 6 characters long.")
        }

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

    static func loginHandler(_ req: Request) async throws -> AuthResponse {
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

    static func profileHandler(_ req: Request) throws -> User.Public {
        let user = try req.auth.require(User.self)
        return user.convertToPublic()
    }
    
    static func updatePasswordHandler(_ req: Request) async throws -> HTTPStatus {
        let data = try req.content.decode(UpdatePasswordRequest.self)
        let user = try req.auth.require(User.self)

        guard try Bcrypt.verify(data.currentPassword, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Current password is incorrect.")
        }

        guard data.newPassword.count >= 6 else {
            throw Abort(.badRequest, reason: "New password must be at least 6 characters long.")
        }

        user.passwordHash = try Bcrypt.hash(data.newPassword)
        try await user.save(on: req.db)

        return .ok
    }

    private static func generateToken(for user: User, on req: Request) throws -> String {
        let timestamp = Int(Date().timeIntervalSince1970 + req.application.jwtExpiration)
        let expiration = ExpirationClaim(value: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        let payload = UserPayload(id: try user.requireID(), exp: expiration)
        return try req.jwt.sign(payload)
    }
}
