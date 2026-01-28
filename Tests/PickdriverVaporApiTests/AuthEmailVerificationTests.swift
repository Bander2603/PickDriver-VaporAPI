//
//  AuthEmailVerificationTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 28.01.26.
//

import Foundation
import Vapor
import XCTVapor
import Fluent
@testable import PickdriverVaporApi

final class AuthEmailVerificationTests: XCTestCase {
    private actor CapturingEmailService: EmailService {
        struct SentEmail: Sendable {
            let email: String
            let username: String
            let verificationLink: String
        }

        private var sent: [SentEmail] = []

        func sendVerificationEmail(
            to email: String,
            username: String,
            verificationLink: String,
            on req: Request
        ) async throws {
            sent.append(.init(email: email, username: username, verificationLink: verificationLink))
        }

        func sendPasswordResetEmail(
            to email: String,
            username: String,
            resetLink: String,
            on req: Request
        ) async throws {
            sent.append(.init(email: email, username: username, verificationLink: resetLink))
        }

        func last() -> SentEmail? {
            sent.last
        }

        func count() -> Int {
            sent.count
        }
    }

    func testVerifyEmailLinkSendsEmailAndVerifies() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService
            app.emailVerificationLinkBaseURL = "https://example.test/api/auth/verify-email-link"

            let username = "user_\(UUID().uuidString.prefix(8))"
            let email = "email_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"
            var verificationToken: String?

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let register = try res.content.decode(RegisterResponse.self)
                verificationToken = register.verificationToken
            })

            let sentValue = await emailService.last()
            let sent = try XCTUnwrap(sentValue)
            let token = try XCTUnwrap(verificationToken)
            let components = try XCTUnwrap(URLComponents(string: sent.verificationLink))
            let tokenFromLink = components.queryItems?.first(where: { $0.name == "token" })?.value

            XCTAssertEqual(sent.email, email.lowercased())
            XCTAssertEqual(sent.username, username)
            XCTAssertEqual(components.path, "/api/auth/verify-email-link")
            XCTAssertEqual(tokenFromLink, token)

            try await app.test(.GET, "/api/auth/verify-email-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let auth = try await TestAuth.login(app: app, email: email, password: password)
            XCTAssertFalse(auth.token.isEmpty)
        }
    }

    func testVerifyEmailLinkRedirectsWhenConfigured() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService
            app.emailVerificationSuccessRedirectURL = "https://client.test/verified"

            let username = "user_\(UUID().uuidString.prefix(8))"
            let email = "redir_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"
            var verificationToken: String?

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let register = try res.content.decode(RegisterResponse.self)
                verificationToken = register.verificationToken
            })

            let token = try XCTUnwrap(verificationToken)
            try await app.test(.GET, "/api/auth/verify-email-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertTrue(res.status == .seeOther || res.status == .found)
                let location = try XCTUnwrap(res.headers.first(name: .location))
                let components = try XCTUnwrap(URLComponents(string: location))
                let statusValue = components.queryItems?.first(where: { $0.name == "status" })?.value
                XCTAssertEqual(statusValue, "success")
            })

            let auth = try await TestAuth.login(app: app, email: email, password: password)
            XCTAssertFalse(auth.token.isEmpty)
        }
    }

    func testVerifyEmailLinkRejectsExpiredToken() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService

            let username = "user_\(UUID().uuidString.prefix(8))"
            let email = "expired_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"
            var verificationToken: String?

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let register = try res.content.decode(RegisterResponse.self)
                verificationToken = register.verificationToken
            })

            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let user = try await User.query(on: app.db).filter(\.$email == normalizedEmail).first()
            let dbUser = try XCTUnwrap(user)
            dbUser.emailVerificationExpiresAt = Date().addingTimeInterval(-60)
            try await dbUser.save(on: app.db)

            let token = try XCTUnwrap(verificationToken)
            try await app.test(.GET, "/api/auth/verify-email-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("expired"))
            })
        }
    }

    func testVerifyEmailLinkRedirectsWithErrorStatusWhenExpired() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService
            app.emailVerificationSuccessRedirectURL = "https://client.test/verified"

            let username = "user_\(UUID().uuidString.prefix(8))"
            let email = "expiredredir_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"
            var verificationToken: String?

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let register = try res.content.decode(RegisterResponse.self)
                verificationToken = register.verificationToken
            })

            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let user = try await User.query(on: app.db).filter(\User.$email == normalizedEmail).first()
            let dbUser = try XCTUnwrap(user)
            dbUser.emailVerificationExpiresAt = Date().addingTimeInterval(-60)
            try await dbUser.save(on: app.db)

            let token = try XCTUnwrap(verificationToken)
            try await app.test(.GET, "/api/auth/verify-email-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertTrue(res.status == .seeOther || res.status == .found)
                let location = try XCTUnwrap(res.headers.first(name: .location))
                let components = try XCTUnwrap(URLComponents(string: location))
                let statusValue = components.queryItems?.first(where: { $0.name == "status" })?.value
                let reasonValue = components.queryItems?.first(where: { $0.name == "reason" })?.value
                XCTAssertEqual(statusValue, "error")
                XCTAssertEqual(reasonValue, "expired")
            })
        }
    }

    func testResendVerificationSendsEmailAgain() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService

            let username = "user_\(UUID().uuidString.prefix(8))"
            let email = "resend_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let firstCount = await emailService.count()
            XCTAssertEqual(firstCount, 1)

            try await app.test(.POST, "/api/auth/resend-verification", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": email
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let secondCount = await emailService.count()
            XCTAssertEqual(secondCount, 2)
        }
    }
}
