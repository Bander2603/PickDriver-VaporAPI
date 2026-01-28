//
//  AuthController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.06.25.
//

import Foundation
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
    let inviteCode: String
}

struct RegisterResponse: Content {
    let user: User.Public
}

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct AuthResponse: Content {
    let user: User.Public
    let token: String
}

struct GoogleAuthRequest: Content {
    let idToken: String
    let inviteCode: String?
}

private enum AuthPolicy {
    static let minUsernameLength = 3
    static let maxUsernameLength = 50
    static let minPasswordLength = 8
    static let maxEmailLength = 100
}

struct AuthController: RouteCollection {
    private static let emailRegex = try! NSRegularExpression(
        pattern: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
        options: [.caseInsensitive]
    )

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")

        auth.post("register", use: Self.registerHandler)
        auth.post("login", use: Self.loginHandler)
        auth.post("google", use: Self.googleAuthHandler)

        let protected = auth.grouped(UserAuthenticator())
        protected.get("profile", use: Self.profileHandler)
        protected.put("password", use: Self.updatePasswordHandler)
    }

    static func registerHandler(_ req: Request) async throws -> RegisterResponse {
        let data = try req.content.decode(RegisterRequest.self)
        let username = normalizeUsername(data.username)
        let email = normalizeEmail(data.email)
        let inviteCode = data.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidUsername(username) else {
            throw Abort(.badRequest, reason: "Username must be 3-50 characters and use only letters, numbers, dots, dashes, or underscores.")
        }
        guard isValidEmail(email) else {
            throw Abort(.badRequest, reason: "Email format is invalid.")
        }
        guard !inviteCode.isEmpty else {
            throw Abort(.badRequest, reason: "Invite code is required.")
        }
        guard data.password.count >= AuthPolicy.minPasswordLength else {
            throw Abort(.badRequest, reason: "Password must be at least \(AuthPolicy.minPasswordLength) characters long.")
        }

        if try await User.query(on: req.db).filter(\.$email == email).first() != nil {
            throw Abort(.conflict, reason: "Email already in use.")
        }
        if try await User.query(on: req.db).filter(\.$username == username).first() != nil {
            throw Abort(.conflict, reason: "Username already in use.")
        }

        let hash = try Bcrypt.hash(data.password)
        let invite = try await requireInviteCode(inviteCode, on: req)

        let user = User(username: username, email: email, passwordHash: hash, emailVerified: true)
        try await user.save(on: req.db)

        if let invite {
            invite.usedAt = Date()
            invite.$usedByUser.id = try user.requireID()
            try await invite.save(on: req.db)
        }

        return RegisterResponse(user: user.convertToPublic())
    }

    static func loginHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(LoginRequest.self)
        let email = normalizeEmail(data.email)

        guard let user = try await User.query(on: req.db).filter(\.$email == email).first() else {
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

        guard data.newPassword != data.currentPassword else {
            throw Abort(.badRequest, reason: "New password must be different from the current password.")
        }
        guard data.newPassword.count >= AuthPolicy.minPasswordLength else {
            throw Abort(.badRequest, reason: "New password must be at least \(AuthPolicy.minPasswordLength) characters long.")
        }

        user.passwordHash = try Bcrypt.hash(data.newPassword)
        try await user.save(on: req.db)

        return .ok
    }

    static func googleAuthHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(GoogleAuthRequest.self)
        let idToken = data.idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idToken.isEmpty else {
            throw Abort(.badRequest, reason: "idToken is required.")
        }
        let tokenInfo = try await verifyGoogleIDToken(idToken, on: req)
        let normalizedEmail = normalizeEmail(tokenInfo.email)

        if let user = try await User.query(on: req.db).filter(\.$googleID == tokenInfo.sub).first() {
            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        if let user = try await User.query(on: req.db).filter(\.$email == normalizedEmail).first() {
            user.googleID = tokenInfo.sub
            user.emailVerified = true
            try await user.save(on: req.db)
            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        guard let inviteCode = data.inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !inviteCode.isEmpty else {
            throw Abort(.forbidden, reason: "Invite code is required.")
        }

        let invite = try await requireInviteCode(inviteCode, on: req)
        let username = try await generateUniqueUsername(
            base: makeUsernameBase(from: tokenInfo, email: normalizedEmail),
            on: req
        )
        let randomPassword = generateTokenString()
        let user = User(username: username, email: normalizedEmail, passwordHash: try Bcrypt.hash(randomPassword), emailVerified: true)
        user.googleID = tokenInfo.sub
        try await user.save(on: req.db)

        if let invite {
            invite.usedAt = Date()
            invite.$usedByUser.id = try user.requireID()
            try await invite.save(on: req.db)
        }

        let token = try generateToken(for: user, on: req)
        return AuthResponse(user: user.convertToPublic(), token: token)
    }

    private static func generateToken(for user: User, on req: Request) throws -> String {
        let timestamp = Int(Date().timeIntervalSince1970 + req.application.jwtExpiration)
        let expiration = ExpirationClaim(value: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        let payload = UserPayload(id: try user.requireID(), exp: expiration)
        return try req.jwt.sign(payload)
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidEmail(_ email: String) -> Bool {
        guard !email.isEmpty, email.count <= AuthPolicy.maxEmailLength else {
            return false
        }
        let range = NSRange(location: 0, length: email.utf16.count)
        return emailRegex.firstMatch(in: email, options: [], range: range) != nil
    }

    private static func isValidUsername(_ username: String) -> Bool {
        guard username.count >= AuthPolicy.minUsernameLength,
              username.count <= AuthPolicy.maxUsernameLength else {
            return false
        }

        return username.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == ".")
        }
    }

    private struct GoogleTokenInfo: Content {
        let sub: String
        let email: String
        let emailVerified: String?
        let aud: String
        let exp: String
        let iss: String?
        let name: String?
        let givenName: String?
        let familyName: String?

        enum CodingKeys: String, CodingKey {
            case sub, email, aud, exp, iss, name
            case emailVerified = "email_verified"
            case givenName = "given_name"
            case familyName = "family_name"
        }
    }

    private static func requireInviteCode(_ code: String, on req: Request) async throws -> InviteCode? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Invite code is required.")
        }

        if let envCode = Environment.get("INVITE_CODE"), !envCode.isEmpty {
            guard trimmed == envCode else {
                throw Abort(.forbidden, reason: "Invalid invite code.")
            }
            return nil
        }

        guard let invite = try await InviteCode.query(on: req.db)
            .filter(\.$code == trimmed)
            .filter(\.$usedAt == nil)
            .first()
        else {
            throw Abort(.forbidden, reason: "Invalid invite code.")
        }

        return invite
    }

    private static func verifyGoogleIDToken(_ idToken: String, on req: Request) async throws -> GoogleTokenInfo {
        guard let clientID = req.application.googleClientID, !clientID.isEmpty else {
            throw Abort(.internalServerError, reason: "Google auth is not configured.")
        }

        var components = URLComponents(string: "https://oauth2.googleapis.com/tokeninfo")
        components?.queryItems = [URLQueryItem(name: "id_token", value: idToken)]
        let endpoint = components?.url?.absoluteString ?? "https://oauth2.googleapis.com/tokeninfo"
        let response = try await req.client.get(URI(string: endpoint))

        guard response.status == .ok else {
            throw Abort(.unauthorized, reason: "Invalid Google token.")
        }

        let info = try response.content.decode(GoogleTokenInfo.self)
        guard info.aud == clientID else {
            throw Abort(.unauthorized, reason: "Invalid Google token.")
        }

        if let issuer = info.iss, issuer != "https://accounts.google.com", issuer != "accounts.google.com" {
            throw Abort(.unauthorized, reason: "Invalid Google token.")
        }

        if let verified = info.emailVerified, verified.lowercased() != "true" {
            throw Abort(.unauthorized, reason: "Google account email not verified.")
        }

        if let exp = Int(info.exp), Date(timeIntervalSince1970: TimeInterval(exp)) <= Date() {
            throw Abort(.unauthorized, reason: "Google token expired.")
        }

        return info
    }

    private static func makeUsernameBase(from info: GoogleTokenInfo, email: String) -> String {
        if let givenName = info.givenName, !givenName.isEmpty {
            return givenName
        }
        let localPart = email.split(separator: "@").first.map(String.init) ?? "user"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let filtered = localPart.unicodeScalars.filter { allowed.contains($0) }
        let base = String(String.UnicodeScalarView(filtered))
        if base.count >= AuthPolicy.minUsernameLength {
            return base
        }
        return "user"
    }

    private static func generateUniqueUsername(base: String, on req: Request) async throws -> String {
        let sanitized = normalizeUsername(base)
        var candidate = sanitized
        if !isValidUsername(candidate) {
            candidate = "user"
        }
        candidate = String(candidate.prefix(AuthPolicy.maxUsernameLength))

        var attempts = 0
        while try await User.query(on: req.db).filter(\.$username == candidate).first() != nil {
            attempts += 1
            let suffix = String(UUID().uuidString.prefix(6))
            let trimmedBase = String(candidate.prefix(AuthPolicy.maxUsernameLength - 7))
            candidate = "\(trimmedBase)_\(suffix)"
            if attempts > 10 {
                candidate = "user_\(UUID().uuidString.prefix(10))"
            }
        }

        return candidate
    }

    private static func generateTokenString() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}
