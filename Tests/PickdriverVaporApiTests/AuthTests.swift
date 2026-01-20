//
//  AuthTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 10.01.26.
//

import XCTVapor
@testable import PickdriverVaporApi

final class AuthTests: XCTestCase {

    func testRegisterThenProfileThenLogin() async throws {
        try await withTestApp { app in
            let created = try await TestAuth.register(app: app)

            // Profile (protected)
            try await app.test(.GET, "/api/auth/profile", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: created.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let user = try res.content.decode(User.Public.self)
                XCTAssertEqual(user.username, created.username)
                XCTAssertEqual(user.email, created.email)
                XCTAssertTrue(user.emailVerified)
            })

            // Login
            let auth = try await TestAuth.login(app: app, email: created.email, password: created.password)
            XCTAssertFalse(auth.token.isEmpty)
            XCTAssertEqual(auth.user.email, created.email)
        }
    }

    func testRegisterValidationUsernameTooShort() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": "ab",
                    "email": "ab_\(UUID().uuidString.prefix(8))@test.com",
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.contains("Username"))
            })
        }
    }

    func testRegisterValidationPasswordTooShort() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": "user_\(UUID().uuidString.prefix(8))",
                    "email": "pw_\(UUID().uuidString.prefix(8))@test.com",
                    "password": "1234567"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.contains("Password"))
            })
        }
    }

    func testRegisterDuplicateEmailReturns409() async throws {
        try await withTestApp { app in
            let email = "dup_\(UUID().uuidString.prefix(8))@test.com"
            _ = try await TestAuth.register(app: app, email: email)

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": "user_\(UUID().uuidString.prefix(8))",
                    "email": email,
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("email"))
            })
        }
    }

    func testRegisterDuplicateUsernameReturns409() async throws {
        try await withTestApp { app in
            let username = "dupuser_\(UUID().uuidString.prefix(8))"
            _ = try await TestAuth.register(app: app, username: username)

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": username,
                    "email": "new_\(UUID().uuidString.prefix(8))@test.com",
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .conflict)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("username"))
            })
        }
    }

    func testLoginRequiresVerifiedEmail() async throws {
        try await withTestApp { app in
            let email = "verify_\(UUID().uuidString.prefix(8))@test.com"
            let password = "12345678"
            var verificationToken: String?

            try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
                try req.content.encode([
                    "username": "user_\(UUID().uuidString.prefix(8))",
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let register = try res.content.decode(RegisterResponse.self)
                verificationToken = register.verificationToken
            })

            try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": email,
                    "password": password
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })

            try await app.test(.POST, "/api/auth/verify-email", beforeRequest: { req async throws in
                try req.content.encode([
                    "token": try XCTUnwrap(verificationToken)
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let auth = try await TestAuth.login(app: app, email: email, password: password)
            XCTAssertFalse(auth.token.isEmpty)
        }
    }

    func testLoginFailsWithWrongPassword() async throws {
        try await withTestApp { app in
            let created = try await TestAuth.register(app: app, password: "12345678")

            try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email,
                    "password": "wrongpass"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.contains("Invalid"))
            })
        }
    }

    func testLoginFailsWithUnknownEmail() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": "unknown_\(UUID().uuidString.prefix(8))@test.com",
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.contains("Invalid"))
            })
        }
    }

    func testProfileRequiresToken() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/auth/profile", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testUpdatePasswordHappyPathAndLoginWithNewPassword() async throws {
        try await withTestApp { app in
            let created = try await TestAuth.register(app: app, password: "12345678")

            // Update password
            try await app.test(.PUT, "/api/auth/password", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: created.token)
                try req.content.encode([
                    "currentPassword": "12345678",
                    "newPassword": "87654321"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            // Old password should fail
            try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
                try req.content.encode([
                    "email": created.email,
                    "password": "12345678"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            // New password should work
            let auth = try await TestAuth.login(app: app, email: created.email, password: "87654321")
            XCTAssertFalse(auth.token.isEmpty)
        }
    }

    func testUpdatePasswordFailsWithWrongCurrentPassword() async throws {
        try await withTestApp { app in
            let created = try await TestAuth.register(app: app, password: "12345678")

            try await app.test(.PUT, "/api/auth/password", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: created.token)
                try req.content.encode([
                    "currentPassword": "wrong",
                    "newPassword": "87654321"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("current password"))
            })
        }
    }

    func testUpdatePasswordFailsWhenNewPasswordTooShort() async throws {
        try await withTestApp { app in
            let created = try await TestAuth.register(app: app, password: "12345678")

            try await app.test(.PUT, "/api/auth/password", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: created.token)
                try req.content.encode([
                    "currentPassword": "12345678",
                    "newPassword": "1234567"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("at least 8"))
            })
        }
    }

    func testUpdatePasswordRequiresToken() async throws {
        try await withTestApp { app in
            try await app.test(.PUT, "/api/auth/password", beforeRequest: { req async throws in
                try req.content.encode([
                    "currentPassword": "12345678",
                    "newPassword": "87654321"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }
}
