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
import Crypto

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

struct RegisterResponse: Content {
    let user: User.Public
    let verificationRequired: Bool
    let verificationToken: String?
}

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct AuthResponse: Content {
    let user: User.Public
    let token: String
}

struct VerifyEmailRequest: Content {
    let token: String
}

struct VerifyEmailResponse: Content {
    let verified: Bool
}

struct ResendVerificationRequest: Content {
    let email: String
}

struct ResendVerificationResponse: Content {
    let message: String
    let verificationToken: String?
}

struct RequestPasswordResetRequest: Content {
    let email: String
}

struct RequestPasswordResetResponse: Content {
    let message: String
    let resetToken: String?
}

struct ResetPasswordRequest: Content {
    let token: String
    let newPassword: String
}

struct ResetPasswordResponse: Content {
    let reset: Bool
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
        auth.post("verify-email", use: Self.verifyEmailHandler)
        auth.get("verify-email-link", use: Self.verifyEmailLinkHandler)
        auth.post("resend-verification", use: Self.resendVerificationHandler)
        auth.post("request-password-reset", use: Self.requestPasswordResetHandler)
        auth.post("reset-password", use: Self.resetPasswordHandler)
        auth.get("reset-password-link", use: Self.resetPasswordLinkHandler)

        let protected = auth.grouped(UserAuthenticator())
        protected.get("profile", use: Self.profileHandler)
        protected.put("password", use: Self.updatePasswordHandler)
    }

    static func registerHandler(_ req: Request) async throws -> RegisterResponse {
        let data = try req.content.decode(RegisterRequest.self)
        let username = normalizeUsername(data.username)
        let email = normalizeEmail(data.email)

        guard isValidUsername(username) else {
            throw Abort(.badRequest, reason: "Username must be 3-50 characters and use only letters, numbers, dots, dashes, or underscores.")
        }
        guard isValidEmail(email) else {
            throw Abort(.badRequest, reason: "Email format is invalid.")
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
        let user = User(username: username, email: email, passwordHash: hash)
        let verification = makeEmailVerificationToken(on: req)
        user.emailVerificationTokenHash = verification.hash
        user.emailVerificationExpiresAt = verification.expiresAt
        user.emailVerificationSentAt = Date()
        try await user.save(on: req.db)

        let verificationLink = makeVerificationLink(for: verification.raw, on: req)
        do {
            try await req.application.emailService.sendVerificationEmail(
                to: user.email,
                username: user.username,
                verificationLink: verificationLink,
                on: req
            )
        } catch {
            req.logger.error("❌ [EMAIL] Failed to send verification email: \(String(reflecting: error))")
        }

        let tokenToReturn = req.application.environment == .production ? nil : verification.raw
        return RegisterResponse(
            user: user.convertToPublic(),
            verificationRequired: true,
            verificationToken: tokenToReturn
        )
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

        guard user.emailVerified else {
            throw Abort(.forbidden, reason: "Email not verified.")
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

    static func verifyEmailHandler(_ req: Request) async throws -> VerifyEmailResponse {
        let data = try req.content.decode(VerifyEmailRequest.self)
        let token = data.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw Abort(.badRequest, reason: "Verification token is required.")
        }

        let status = try await verifyEmailToken(token, on: req)
        guard status == .success else {
            throw Abort(.badRequest, reason: "Invalid or expired token.")
        }

        return VerifyEmailResponse(verified: true)
    }

    static func verifyEmailLinkHandler(_ req: Request) async throws -> Response {
        guard let token = req.query[String.self, at: "token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            if let redirectURL = req.application.emailVerificationSuccessRedirectURL {
                let redirectWithStatus = makeRedirectURL(
                    base: redirectURL,
                    status: "error",
                    reason: "missing_token"
                )
                return req.redirect(to: redirectWithStatus)
            }
            throw Abort(.badRequest, reason: "Verification token is required.")
        }

        let status = try await verifyEmailToken(token, on: req)

        if let redirectURL = req.application.emailVerificationSuccessRedirectURL {
            switch status {
            case .success:
                let redirectWithStatus = makeRedirectURL(base: redirectURL, status: "success", reason: nil)
                return req.redirect(to: redirectWithStatus)
            case .invalid:
                let redirectWithStatus = makeRedirectURL(base: redirectURL, status: "error", reason: "invalid")
                return req.redirect(to: redirectWithStatus)
            case .expired:
                let redirectWithStatus = makeRedirectURL(base: redirectURL, status: "error", reason: "expired")
                return req.redirect(to: redirectWithStatus)
            }
        }

        guard status == .success else {
            throw Abort(.badRequest, reason: "Invalid or expired token.")
        }

        return Response(status: .ok, body: .init(string: "Email verified. You can close this window."))
    }

    static func resendVerificationHandler(_ req: Request) async throws -> ResendVerificationResponse {
        let data = try req.content.decode(ResendVerificationRequest.self)
        let email = normalizeEmail(data.email)
        let now = Date()
        var tokenToReturn: String?

        if let user = try await User.query(on: req.db).filter(\.$email == email).first() {
            if !user.emailVerified {
                let minInterval = req.application.emailVerificationResendInterval
                let shouldThrottle = req.application.environment == .production &&
                    user.emailVerificationSentAt.map { now.timeIntervalSince($0) < minInterval } == true

                if !shouldThrottle {
                    let verification = makeEmailVerificationToken(on: req)
                    user.emailVerificationTokenHash = verification.hash
                    user.emailVerificationExpiresAt = verification.expiresAt
                    user.emailVerificationSentAt = now
                    try await user.save(on: req.db)

                    let verificationLink = makeVerificationLink(for: verification.raw, on: req)
                    do {
                        try await req.application.emailService.sendVerificationEmail(
                            to: user.email,
                            username: user.username,
                            verificationLink: verificationLink,
                            on: req
                        )
                    } catch {
                        req.logger.error("❌ [EMAIL] Failed to resend verification email: \(String(reflecting: error))")
                    }

                    if req.application.environment != .production {
                        tokenToReturn = verification.raw
                    }
                }
            }
        }

        return ResendVerificationResponse(
            message: "If the account exists, a verification email has been sent.",
            verificationToken: tokenToReturn
        )
    }

    static func requestPasswordResetHandler(_ req: Request) async throws -> RequestPasswordResetResponse {
        let data = try req.content.decode(RequestPasswordResetRequest.self)
        let email = normalizeEmail(data.email)
        let now = Date()
        var tokenToReturn: String?

        if let user = try await User.query(on: req.db).filter(\.$email == email).first() {
            let minInterval = req.application.passwordResetResendInterval
            let shouldThrottle = req.application.environment == .production &&
                user.passwordResetSentAt.map { now.timeIntervalSince($0) < minInterval } == true

            if !shouldThrottle {
                let reset = makePasswordResetToken(on: req)
                user.passwordResetTokenHash = reset.hash
                user.passwordResetExpiresAt = reset.expiresAt
                user.passwordResetSentAt = now
                try await user.save(on: req.db)

                let resetLink = makePasswordResetLink(for: reset.raw, on: req)
                do {
                    try await req.application.emailService.sendPasswordResetEmail(
                        to: user.email,
                        username: user.username,
                        resetLink: resetLink,
                        on: req
                    )
                } catch {
                    req.logger.error("❌ [EMAIL] Failed to send password reset email: \(String(reflecting: error))")
                }

                if req.application.environment != .production {
                    tokenToReturn = reset.raw
                }
            }
        }

        return RequestPasswordResetResponse(
            message: "If the account exists, a password reset email has been sent.",
            resetToken: tokenToReturn
        )
    }

    static func resetPasswordHandler(_ req: Request) async throws -> ResetPasswordResponse {
        let data = try req.content.decode(ResetPasswordRequest.self)
        let token = data.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw Abort(.badRequest, reason: "Reset token is required.")
        }
        guard data.newPassword.count >= AuthPolicy.minPasswordLength else {
            throw Abort(.badRequest, reason: "Password must be at least \(AuthPolicy.minPasswordLength) characters long.")
        }

        let result = try await passwordResetStatus(for: token, on: req)
        guard result.status == .success, let user = result.user else {
            throw Abort(.badRequest, reason: "Invalid or expired token.")
        }

        user.passwordHash = try Bcrypt.hash(data.newPassword)
        user.passwordResetTokenHash = nil
        user.passwordResetExpiresAt = nil
        user.passwordResetSentAt = nil
        try await user.save(on: req.db)

        return ResetPasswordResponse(reset: true)
    }

    static func resetPasswordLinkHandler(_ req: Request) async throws -> Response {
        guard let token = req.query[String.self, at: "token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            if let redirectURL = req.application.passwordResetRedirectURL {
                let redirectWithStatus = makeRedirectURL(
                    base: redirectURL,
                    status: "error",
                    reason: "missing_token"
                )
                return req.redirect(to: redirectWithStatus)
            }
            throw Abort(.badRequest, reason: "Reset token is required.")
        }

        let result = try await passwordResetStatus(for: token, on: req)

        if let redirectURL = req.application.passwordResetRedirectURL {
            switch result.status {
            case .success:
                let redirectWithStatus = makeRedirectURL(
                    base: redirectURL,
                    status: "success",
                    reason: nil,
                    extraQueryItems: [URLQueryItem(name: "token", value: token)]
                )
                return req.redirect(to: redirectWithStatus)
            case .invalid:
                let redirectWithStatus = makeRedirectURL(
                    base: redirectURL,
                    status: "error",
                    reason: "invalid"
                )
                return req.redirect(to: redirectWithStatus)
            case .expired:
                let redirectWithStatus = makeRedirectURL(
                    base: redirectURL,
                    status: "error",
                    reason: "expired"
                )
                return req.redirect(to: redirectWithStatus)
            }
        }

        guard result.status == .success else {
            throw Abort(.badRequest, reason: "Invalid or expired token.")
        }

        return Response(status: .ok, body: .init(string: "Reset token is valid. You can close this window."))
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

    private static func makeEmailVerificationToken(on req: Request) -> (raw: String, hash: String, expiresAt: Date) {
        let raw = generateTokenString()
        let hash = hashToken(raw)
        let expiresAt = Date().addingTimeInterval(req.application.emailVerificationExpiration)
        return (raw: raw, hash: hash, expiresAt: expiresAt)
    }

    private enum TokenStatus {
        case success
        case invalid
        case expired
    }

    private static func verifyEmailToken(_ token: String, on req: Request) async throws -> TokenStatus {
        let tokenHash = hashToken(token)
        guard let user = try await User.query(on: req.db)
            .filter(\.$emailVerificationTokenHash == tokenHash)
            .first()
        else {
            return .invalid
        }

        guard let expiresAt = user.emailVerificationExpiresAt else {
            return .invalid
        }

        guard expiresAt > Date() else {
            return .expired
        }

        if !user.emailVerified {
            user.emailVerified = true
            user.emailVerificationTokenHash = nil
            user.emailVerificationExpiresAt = nil
            user.emailVerificationSentAt = nil
            try await user.save(on: req.db)
        }

        return .success
    }

    private static func makeVerificationLink(for token: String, on req: Request) -> String {
        guard var components = URLComponents(string: req.application.emailVerificationLinkBaseURL) else {
            return req.application.emailVerificationLinkBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: token))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? req.application.emailVerificationLinkBaseURL
    }

    private static func makePasswordResetToken(on req: Request) -> (raw: String, hash: String, expiresAt: Date) {
        let raw = generateTokenString()
        let hash = hashToken(raw)
        let expiresAt = Date().addingTimeInterval(req.application.passwordResetExpiration)
        return (raw: raw, hash: hash, expiresAt: expiresAt)
    }

    private static func passwordResetStatus(for token: String, on req: Request) async throws -> (status: TokenStatus, user: User?) {
        let tokenHash = hashToken(token)
        guard let user = try await User.query(on: req.db)
            .filter(\.$passwordResetTokenHash == tokenHash)
            .first()
        else {
            return (status: .invalid, user: nil)
        }

        guard let expiresAt = user.passwordResetExpiresAt else {
            return (status: .invalid, user: nil)
        }

        guard expiresAt > Date() else {
            return (status: .expired, user: nil)
        }

        return (status: .success, user: user)
    }

    private static func makePasswordResetLink(for token: String, on req: Request) -> String {
        guard var components = URLComponents(string: req.application.passwordResetLinkBaseURL) else {
            return req.application.passwordResetLinkBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: token))
        components.queryItems = queryItems
        return components.url?.absoluteString ?? req.application.passwordResetLinkBaseURL
    }

    private static func makeRedirectURL(
        base: String,
        status: String,
        reason: String?,
        extraQueryItems: [URLQueryItem] = []
    ) -> String {
        guard var components = URLComponents(string: base) else {
            return base
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "status", value: status))
        if let reason {
            queryItems.append(URLQueryItem(name: "reason", value: reason))
        }
        if !extraQueryItems.isEmpty {
            queryItems.append(contentsOf: extraQueryItems)
        }
        components.queryItems = queryItems
        return components.url?.absoluteString ?? base
    }

    private static func generateTokenString() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
