//
//  AuthController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.06.25.
//

import Foundation
import Crypto
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

struct RegisterResponse: Content {
    let user: User.Public
    let verificationEmailSent: Bool
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
}

struct AppleAuthRequest: Content {
    let idToken: String
    let email: String?
    let firstName: String?
    let lastName: String?
}

struct ResendVerificationRequest: Content {
    let email: String
}

struct ForgotPasswordRequest: Content {
    let email: String
}

struct ResetPasswordRequest: Content {
    let token: String
    let newPassword: String
}

struct TokenQuery: Content {
    let token: String
}

struct AuthMessageResponse: Content {
    let message: String
}

private enum AuthPolicy {
    static let minUsernameLength = 3
    static let maxUsernameLength = 20
    static let minPasswordLength = 8
    static let maxEmailLength = 100
}

private enum AccountDeletionPolicy {
    static let maxPersistedUsernameLength = 50
    static let usernameSuffix = " (usuario borrado)"
    static let fallbackUsername = "Usuario"
    static let deletedEmailDomain = "deleted.pickdriver.local"
}

struct AuthController: RouteCollection {
    private static let emailRegex = try! NSRegularExpression(
        pattern: "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$",
        options: [.caseInsensitive]
    )

    private static let genericVerificationMessage = AuthMessageResponse(
        message: "If the account exists and is pending verification, a verification email has been sent."
    )

    private static let genericResetMessage = AuthMessageResponse(
        message: "If the account exists, password reset instructions have been sent."
    )

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")

        auth.post("register", use: Self.registerHandler)
        auth.post("login", use: Self.loginHandler)
        auth.post("google", use: Self.googleAuthHandler)
        auth.post("apple", use: Self.appleAuthHandler)
        auth.post("resend-verification", use: Self.resendVerificationHandler)
        auth.get("verify-email-link", use: Self.verifyEmailLinkHandler)
        auth.post("forgot-password", use: Self.forgotPasswordHandler)
        auth.get("reset-password-link", use: Self.resetPasswordLinkHandler)
        auth.post("reset-password", use: Self.resetPasswordHandler)

        let protected = auth.grouped(UserAuthenticator())
        protected.get("profile", use: Self.profileHandler)
        protected.put("password", use: Self.updatePasswordHandler)
        protected.put("username", use: Self.updateUsernameHandler)
        protected.delete("account", use: Self.deleteAccountHandler)
    }

    static func registerHandler(_ req: Request) async throws -> RegisterResponse {
        let data = try req.content.decode(RegisterRequest.self)
        let username = normalizeUsername(data.username)
        let email = normalizeEmail(data.email)

        guard isValidUsername(username) else {
            throw Abort(.badRequest, reason: "Username must be 3-20 characters and use only letters, numbers, dots, dashes, or underscores.")
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
        let user = User(username: username, email: email, passwordHash: hash, emailVerified: false)
        try await user.save(on: req.db)

        let verificationEmailSent = await sendVerificationEmail(for: user, on: req, enforceResendInterval: false)
        return RegisterResponse(user: user.convertToPublic(), verificationEmailSent: verificationEmailSent)
    }

    static func loginHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(LoginRequest.self)
        let email = normalizeEmail(data.email)

        guard let user = try await User.query(on: req.db).filter(\.$email == email).first() else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        guard user.deletedAt == nil else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        guard try Bcrypt.verify(data.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        guard user.emailVerified else {
            throw Abort(.forbidden, reason: "Email not verified. Please verify your email before logging in.")
        }

        let token = try generateToken(for: user, on: req)
        return AuthResponse(user: user.convertToPublic(), token: token)
    }

    static func resendVerificationHandler(_ req: Request) async throws -> AuthMessageResponse {
        let data = try req.content.decode(ResendVerificationRequest.self)
        let email = normalizeEmail(data.email)

        guard isValidEmail(email) else {
            return genericVerificationMessage
        }

        guard let user = try await User.query(on: req.db).filter(\.$email == email).first(), !user.emailVerified else {
            return genericVerificationMessage
        }

        _ = await sendVerificationEmail(for: user, on: req, enforceResendInterval: true)
        return genericVerificationMessage
    }

    static func verifyEmailLinkHandler(_ req: Request) async throws -> Response {
        guard let query = try? req.query.decode(TokenQuery.self) else {
            return try verificationFailureResponse(on: req)
        }

        let rawToken = query.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawToken.isEmpty, rawToken.count <= 1024 else {
            return try verificationFailureResponse(on: req)
        }

        let tokenHash = hashToken(rawToken)
        guard let user = try await User.query(on: req.db)
            .filter(\.$emailVerificationTokenHash == tokenHash)
            .first()
        else {
            return try verificationFailureResponse(on: req)
        }

        guard let expiresAt = user.emailVerificationExpiresAt, expiresAt > Date() else {
            user.emailVerificationTokenHash = nil
            user.emailVerificationExpiresAt = nil
            try await user.save(on: req.db)
            return try verificationFailureResponse(on: req)
        }

        user.emailVerified = true
        user.emailVerificationTokenHash = nil
        user.emailVerificationExpiresAt = nil
        user.emailVerificationSentAt = nil
        try await user.save(on: req.db)

        return try verificationSuccessResponse(on: req)
    }

    static func forgotPasswordHandler(_ req: Request) async throws -> AuthMessageResponse {
        let data = try req.content.decode(ForgotPasswordRequest.self)
        let email = normalizeEmail(data.email)

        guard isValidEmail(email) else {
            return genericResetMessage
        }

        guard let user = try await User.query(on: req.db).filter(\.$email == email).first() else {
            return genericResetMessage
        }

        _ = await sendPasswordResetEmail(for: user, on: req, enforceResendInterval: true)
        return genericResetMessage
    }

    static func resetPasswordLinkHandler(_ req: Request) throws -> Response {
        guard let query = try? req.query.decode(TokenQuery.self) else {
            throw Abort(.badRequest, reason: "Reset token is required.")
        }

        let rawToken = query.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawToken.isEmpty else {
            throw Abort(.badRequest, reason: "Reset token is required.")
        }

        if let redirect = req.application.passwordResetRedirectURL {
            let location = addQueryItems(
                to: redirect,
                items: [URLQueryItem(name: "token", value: rawToken)]
            )
            return req.redirect(to: location)
        }

        let response = Response(status: .ok)
        try response.content.encode(
            AuthMessageResponse(
                message: "Token received. Use POST /api/auth/reset-password with token and newPassword."
            )
        )
        return response
    }

    static func resetPasswordHandler(_ req: Request) async throws -> AuthMessageResponse {
        let data = try req.content.decode(ResetPasswordRequest.self)
        let rawToken = data.token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawToken.isEmpty else {
            throw Abort(.badRequest, reason: "Reset token is required.")
        }
        guard data.newPassword.count >= AuthPolicy.minPasswordLength else {
            throw Abort(.badRequest, reason: "New password must be at least \(AuthPolicy.minPasswordLength) characters long.")
        }

        let tokenHash = hashToken(rawToken)
        guard let user = try await User.query(on: req.db)
            .filter(\.$passwordResetTokenHash == tokenHash)
            .first(),
              let expiresAt = user.passwordResetExpiresAt,
              expiresAt > Date()
        else {
            throw Abort(.badRequest, reason: "Invalid or expired password reset token.")
        }

        guard try !Bcrypt.verify(data.newPassword, created: user.passwordHash) else {
            throw Abort(.badRequest, reason: "New password must be different from the current password.")
        }

        user.passwordHash = try Bcrypt.hash(data.newPassword)
        user.passwordResetTokenHash = nil
        user.passwordResetExpiresAt = nil
        user.passwordResetSentAt = nil
        user.emailVerified = true
        user.emailVerificationTokenHash = nil
        user.emailVerificationExpiresAt = nil
        user.emailVerificationSentAt = nil

        try await user.save(on: req.db)
        return AuthMessageResponse(message: "Password updated successfully.")
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

    static func updateUsernameHandler(_ req: Request) async throws -> User.Public {
        let data = try req.content.decode(UpdateUsernameRequest.self)
        let user = try req.auth.require(User.self)
        let username = normalizeUsername(data.username)

        guard isValidUsername(username) else {
            throw Abort(.badRequest, reason: "Username must be 3-20 characters and use only letters, numbers, dots, dashes, or underscores.")
        }

        if username == user.username {
            return user.convertToPublic()
        }

        let userID = try user.requireID()
        if try await User.query(on: req.db)
            .filter(\.$username == username)
            .filter(\.$id != userID)
            .first() != nil {
            throw Abort(.conflict, reason: "Username already in use.")
        }

        user.username = username
        try await user.save(on: req.db)

        return user.convertToPublic()
    }

    static func deleteAccountHandler(_ req: Request) async throws -> HTTPStatus {
        let authUser = try req.auth.require(User.self)
        let userID = try authUser.requireID()
        let now = Date()

        try await req.db.transaction { tx in
            guard let user = try await User.find(userID, on: tx) else {
                throw Abort(.notFound, reason: "User not found.")
            }

            guard user.deletedAt == nil else {
                return
            }

            let memberships = try await LeagueMember.query(on: tx)
                .filter(\.$user.$id == userID)
                .all()

            let leagueIDs = memberships.map { $0.$league.id }
            var pendingOwnedLeagueIDs: [Int] = []
            var pendingMemberLeagueIDs: [Int] = []

            if !leagueIDs.isEmpty {
                let leagues = try await League.query(on: tx)
                    .filter(\.$id ~~ leagueIDs)
                    .all()

                for league in leagues {
                    guard let leagueID = league.id else { continue }
                    guard league.status.lowercased() == "pending" else { continue }

                    if league.$creator.id == userID {
                        pendingOwnedLeagueIDs.append(leagueID)
                    } else {
                        pendingMemberLeagueIDs.append(leagueID)
                    }
                }
            }

            if !pendingOwnedLeagueIDs.isEmpty {
                let ownedPendingLeagues = try await League.query(on: tx)
                    .filter(\.$id ~~ pendingOwnedLeagueIDs)
                    .all()

                for league in ownedPendingLeagues {
                    try await league.delete(on: tx)
                }
            }

            if !pendingMemberLeagueIDs.isEmpty {
                let pendingTeamIDs = try await LeagueTeam.query(on: tx)
                    .filter(\.$league.$id ~~ pendingMemberLeagueIDs)
                    .all()
                    .compactMap(\.id)

                if !pendingTeamIDs.isEmpty {
                    try await TeamMember.query(on: tx)
                        .filter(\.$user.$id == userID)
                        .filter(\.$team.$id ~~ pendingTeamIDs)
                        .delete()
                }

                try await LeagueMember.query(on: tx)
                    .filter(\.$user.$id == userID)
                    .filter(\.$league.$id ~~ pendingMemberLeagueIDs)
                    .delete()
            }

            try await PlayerAutopick.query(on: tx)
                .filter(\.$user.$id == userID)
                .delete()

            let pushTokens = try await PushToken.query(on: tx)
                .filter(\.$user.$id == userID)
                .all()

            for token in pushTokens {
                token.isActive = false
                token.lastSeenAt = now
                try await token.save(on: tx)
            }

            user.username = makeDeletedUsername(from: user.username)
            user.email = makeDeletedEmail(for: userID, at: now)
            user.passwordHash = try Bcrypt.hash("deleted-\(UUID().uuidString)-\(generateTokenString())")
            user.emailVerified = false
            user.googleID = nil
            user.appleID = nil
            user.emailVerificationTokenHash = nil
            user.emailVerificationExpiresAt = nil
            user.emailVerificationSentAt = nil
            user.passwordResetTokenHash = nil
            user.passwordResetExpiresAt = nil
            user.passwordResetSentAt = nil
            user.deletedAt = now

            try await user.save(on: tx)
        }

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

        if let user = try await User.query(on: req.db)
            .filter(\.$googleID == tokenInfo.sub)
            .filter(\.$deletedAt == nil)
            .first() {
            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        if let user = try await User.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$deletedAt == nil)
            .first() {
            user.googleID = tokenInfo.sub
            user.emailVerified = true
            user.emailVerificationTokenHash = nil
            user.emailVerificationExpiresAt = nil
            user.emailVerificationSentAt = nil
            try await user.save(on: req.db)

            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        let username = try await generateUniqueUsername(
            base: makeUsernameBase(from: tokenInfo, email: normalizedEmail),
            on: req
        )
        let randomPassword = generateTokenString()
        let user = User(username: username, email: normalizedEmail, passwordHash: try Bcrypt.hash(randomPassword), emailVerified: true)
        user.googleID = tokenInfo.sub
        try await user.save(on: req.db)

        let token = try generateToken(for: user, on: req)
        return AuthResponse(user: user.convertToPublic(), token: token)
    }

    static func appleAuthHandler(_ req: Request) async throws -> AuthResponse {
        let data = try req.content.decode(AppleAuthRequest.self)
        let idToken = data.idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idToken.isEmpty else {
            throw Abort(.badRequest, reason: "idToken is required.")
        }

        let tokenInfo = try await verifyAppleIDToken(idToken, on: req)
        let appleSubject = tokenInfo.subject.value

        if let user = try await User.query(on: req.db)
            .filter(\.$appleID == appleSubject)
            .filter(\.$deletedAt == nil)
            .first() {
            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        let tokenEmail = tokenInfo.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEmail = data.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRawEmail = (tokenEmail?.isEmpty == false) ? tokenEmail : ((fallbackEmail?.isEmpty == false) ? fallbackEmail : nil)
        guard let resolvedRawEmail else {
            throw Abort(
                .badRequest,
                reason: "Apple token did not provide email. Sign in once with email sharing enabled or provide an email from the client."
            )
        }

        let normalizedEmail = normalizeEmail(resolvedRawEmail)
        guard isValidEmail(normalizedEmail) else {
            throw Abort(.badRequest, reason: "Email format is invalid.")
        }

        if let user = try await User.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$deletedAt == nil)
            .first() {
            user.appleID = appleSubject
            user.emailVerified = true
            user.emailVerificationTokenHash = nil
            user.emailVerificationExpiresAt = nil
            user.emailVerificationSentAt = nil
            try await user.save(on: req.db)
            let token = try generateToken(for: user, on: req)
            return AuthResponse(user: user.convertToPublic(), token: token)
        }

        let username = try await generateUniqueUsername(
            base: makeUsernameBase(firstName: data.firstName, lastName: data.lastName, email: normalizedEmail),
            on: req
        )
        let randomPassword = generateTokenString()
        let user = User(username: username, email: normalizedEmail, passwordHash: try Bcrypt.hash(randomPassword), emailVerified: true)
        user.appleID = appleSubject
        try await user.save(on: req.db)

        let token = try generateToken(for: user, on: req)
        return AuthResponse(user: user.convertToPublic(), token: token)
    }

    private static func sendVerificationEmail(
        for user: User,
        on req: Request,
        enforceResendInterval: Bool
    ) async -> Bool {
        do {
            let now = Date()
            if enforceResendInterval,
               isRateLimited(lastSentAt: user.emailVerificationSentAt, interval: req.application.emailVerificationResendInterval, now: now) {
                return false
            }

            let rawToken = generateTokenString()
            user.emailVerificationTokenHash = hashToken(rawToken)
            user.emailVerificationExpiresAt = now.addingTimeInterval(req.application.emailVerificationExpiration)
            user.emailVerificationSentAt = now
            try await user.save(on: req.db)

            let verificationLink = addQueryItems(
                to: req.application.emailVerificationLinkBaseURL,
                items: [URLQueryItem(name: "token", value: rawToken)]
            )
            try await req.application.emailService.sendVerificationEmail(
                to: user.email,
                username: user.username,
                verificationLink: verificationLink,
                on: req
            )
            return true
        } catch {
            req.logger.error("Failed to send verification email", metadata: ["error": "\(error.localizedDescription)"])
            return false
        }
    }

    private static func sendPasswordResetEmail(
        for user: User,
        on req: Request,
        enforceResendInterval: Bool
    ) async -> Bool {
        do {
            let now = Date()
            if enforceResendInterval,
               isRateLimited(lastSentAt: user.passwordResetSentAt, interval: req.application.passwordResetResendInterval, now: now) {
                return false
            }

            let rawToken = generateTokenString()
            user.passwordResetTokenHash = hashToken(rawToken)
            user.passwordResetExpiresAt = now.addingTimeInterval(req.application.passwordResetExpiration)
            user.passwordResetSentAt = now
            try await user.save(on: req.db)

            let resetLink = addQueryItems(
                to: req.application.passwordResetLinkBaseURL,
                items: [URLQueryItem(name: "token", value: rawToken)]
            )
            try await req.application.emailService.sendPasswordResetEmail(
                to: user.email,
                username: user.username,
                resetLink: resetLink,
                on: req
            )
            return true
        } catch {
            req.logger.error("Failed to send password reset email", metadata: ["error": "\(error.localizedDescription)"])
            return false
        }
    }

    private static func isRateLimited(lastSentAt: Date?, interval: Double, now: Date) -> Bool {
        guard interval > 0, let lastSentAt else {
            return false
        }
        return now.timeIntervalSince(lastSentAt) < interval
    }

    private static func verificationSuccessResponse(on req: Request) throws -> Response {
        if let redirect = req.application.emailVerificationSuccessRedirectURL {
            let location = addQueryItems(
                to: redirect,
                items: [URLQueryItem(name: "status", value: "success")]
            )
            return req.redirect(to: location)
        }

        let response = Response(status: .ok)
        try response.content.encode(AuthMessageResponse(message: "Email verified successfully."))
        return response
    }

    private static func verificationFailureResponse(on req: Request) throws -> Response {
        if let redirect = req.application.emailVerificationSuccessRedirectURL {
            let location = addQueryItems(
                to: redirect,
                items: [URLQueryItem(name: "status", value: "invalid")]
            )
            return req.redirect(to: location)
        }

        throw Abort(.badRequest, reason: "Invalid or expired verification token.")
    }

    private static func addQueryItems(to baseURL: String, items: [URLQueryItem]) -> String {
        guard var components = URLComponents(string: baseURL) else {
            return baseURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: items)
        components.queryItems = queryItems

        return components.url?.absoluteString ?? baseURL
    }

    private static func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    private static func verifyGoogleIDToken(_ idToken: String, on req: Request) async throws -> GoogleTokenInfo {
        guard !req.application.googleClientIDs.isEmpty else {
            throw Abort(.internalServerError, reason: "Google auth is not configured. Set GOOGLE_CLIENT_ID or GOOGLE_CLIENT_IDS.")
        }

        var components = URLComponents(string: "https://oauth2.googleapis.com/tokeninfo")
        components?.queryItems = [URLQueryItem(name: "id_token", value: idToken)]
        let endpoint = components?.url?.absoluteString ?? "https://oauth2.googleapis.com/tokeninfo"
        let response = try await req.client.get(URI(string: endpoint))

        guard response.status == .ok else {
            throw Abort(.unauthorized, reason: "Invalid Google token.")
        }

        let info = try response.content.decode(GoogleTokenInfo.self)
        guard req.application.googleClientIDs.contains(info.aud) else {
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

    private static func verifyAppleIDToken(_ idToken: String, on req: Request) async throws -> AppleIdentityToken {
        guard !req.application.appleClientIDs.isEmpty else {
            throw Abort(.internalServerError, reason: "Apple auth is not configured. Set APPLE_CLIENT_ID or APPLE_CLIENT_IDS.")
        }

        var lastError: (any Error)?
        for clientID in req.application.appleClientIDs {
            do {
                return try await req.jwt.apple.verify(idToken, applicationIdentifier: clientID)
            } catch {
                lastError = error
            }
        }

        req.logger.warning("Apple token verification failed for all configured client IDs: \(String(describing: lastError))")
        throw Abort(.unauthorized, reason: "Invalid Apple token.")
    }

    private static func makeUsernameBase(firstName: String?, lastName: String?, email: String) -> String {
        if let firstName = firstName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let candidate = sanitizeUsernameBase(firstName) {
            return candidate
        }

        if let lastName = lastName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let candidate = sanitizeUsernameBase(lastName) {
            return candidate
        }

        return makeUsernameBase(fromEmail: email)
    }

    private static func makeUsernameBase(from info: GoogleTokenInfo, email: String) -> String {
        if let givenName = info.givenName,
           let candidate = sanitizeUsernameBase(givenName) {
            return candidate
        }

        if let name = info.name,
           let firstPart = name.split(separator: " ").first,
           let candidate = sanitizeUsernameBase(String(firstPart)) {
            return candidate
        }

        return makeUsernameBase(fromEmail: email)
    }

    private static func makeUsernameBase(fromEmail email: String) -> String {
        let localPart = email.split(separator: "@").first.map(String.init) ?? "user"
        if let candidate = sanitizeUsernameBase(localPart) {
            return candidate
        }
        return "user"
    }

    private static func sanitizeUsernameBase(_ input: String) -> String? {
        guard !input.isEmpty else {
            return nil
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let filtered = input.unicodeScalars.filter { scalar in
            scalar.isASCII && allowed.contains(scalar)
        }
        let base = String(String.UnicodeScalarView(filtered))

        guard base.count >= AuthPolicy.minUsernameLength else {
            return nil
        }

        return String(base.prefix(AuthPolicy.maxUsernameLength))
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

    private static func makeDeletedUsername(from current: String) -> String {
        let normalized = normalizeUsername(current)
        let base = normalized.isEmpty ? AccountDeletionPolicy.fallbackUsername : normalized
        let maxBaseLength = max(1, AccountDeletionPolicy.maxPersistedUsernameLength - AccountDeletionPolicy.usernameSuffix.count)
        let trimmedBase = String(base.prefix(maxBaseLength))
        return "\(trimmedBase)\(AccountDeletionPolicy.usernameSuffix)"
    }

    private static func makeDeletedEmail(for userID: Int, at date: Date) -> String {
        let timestamp = Int(date.timeIntervalSince1970)
        return "deleted+\(userID)+\(timestamp)@\(AccountDeletionPolicy.deletedEmailDomain)"
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
