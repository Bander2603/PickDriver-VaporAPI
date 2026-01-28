//
//  AuthPasswordResetTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 28.01.26.
//

import Foundation
import Vapor
import XCTVapor
@testable import PickdriverVaporApi

final class AuthPasswordResetTests: XCTestCase {
    private actor CapturingEmailService: EmailService {
        struct SentEmail: Sendable {
            let email: String
            let username: String
            let link: String
        }

        private var sent: [SentEmail] = []

        func sendVerificationEmail(
            to email: String,
            username: String,
            verificationLink: String,
            on req: Request
        ) async throws {
            sent.append(.init(email: email, username: username, link: verificationLink))
        }

        func sendPasswordResetEmail(
            to email: String,
            username: String,
            resetLink: String,
            on req: Request
        ) async throws {
            sent.append(.init(email: email, username: username, link: resetLink))
        }

        func last() -> SentEmail? {
            sent.last
        }
    }

    func testPasswordResetFlow() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService

            let created = try await TestAuth.register(app: app, password: "12345678")

            var resetToken: String?
            try await app.test(.POST, "/api/auth/request-password-reset", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(RequestPasswordResetResponse.self)
                resetToken = response.resetToken
            })

            let sentValue = await emailService.last()
            let sent = try XCTUnwrap(sentValue)
            let token = try XCTUnwrap(resetToken)
            let components = try XCTUnwrap(URLComponents(string: sent.link))
            let tokenFromLink = components.queryItems?.first(where: { $0.name == "token" })?.value

            XCTAssertEqual(sent.email, created.email)
            XCTAssertEqual(sent.username, created.username)
            XCTAssertEqual(tokenFromLink, token)

            try await app.test(.GET, "/api/auth/reset-password-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            try await app.test(.POST, "/api/auth/reset-password", beforeRequest: { req async throws in
                try req.content.encode([
                    "token": token,
                    "newPassword": "87654321"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email,
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            let auth = try await TestAuth.login(app: app, email: created.email, password: "87654321")
            XCTAssertFalse(auth.token.isEmpty)
        }
    }

    func testPasswordResetLinkRedirectsWithStatusAndToken() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService
            app.passwordResetRedirectURL = "https://client.test/reset"

            let created = try await TestAuth.register(app: app, password: "12345678")
            var resetToken: String?

            try await app.test(.POST, "/api/auth/request-password-reset", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(RequestPasswordResetResponse.self)
                resetToken = response.resetToken
            })

            let token = try XCTUnwrap(resetToken)
            try await app.test(.GET, "/api/auth/reset-password-link?token=\(token)", afterResponse: { res async throws in
                XCTAssertTrue(res.status == .seeOther || res.status == .found)
                let location = try XCTUnwrap(res.headers.first(name: .location))
                let components = try XCTUnwrap(URLComponents(string: location))
                let statusValue = components.queryItems?.first(where: { $0.name == "status" })?.value
                let tokenValue = components.queryItems?.first(where: { $0.name == "token" })?.value
                XCTAssertEqual(statusValue, "success")
                XCTAssertEqual(tokenValue, token)
            })
        }
    }

    func testPasswordResetLinkRedirectsWithErrorWhenExpired() async throws {
        try await withTestApp { app in
            let emailService = CapturingEmailService()
            app.emailService = emailService
            app.passwordResetRedirectURL = "https://client.test/reset"

            let created = try await TestAuth.register(app: app, password: "12345678")
            var resetToken: String?

            try await app.test(.POST, "/api/auth/request-password-reset", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(RequestPasswordResetResponse.self)
                resetToken = response.resetToken
            })

            let normalizedEmail = created.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let user = try await User.query(on: app.db).filter(\User.$email, .equal, normalizedEmail).first()
            let dbUser = try XCTUnwrap(user)
            dbUser.passwordResetExpiresAt = Date().addingTimeInterval(-60)
            try await dbUser.save(on: app.db)

            let token = try XCTUnwrap(resetToken)
            try await app.test(.GET, "/api/auth/reset-password-link?token=\(token)", afterResponse: { res async throws in
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
}
