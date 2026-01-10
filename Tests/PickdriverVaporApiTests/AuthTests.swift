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
        let app = try await TestApp.make()
        defer { Task { await TestApp.shutdown(app) } }

        let username = "user_\(UUID().uuidString.prefix(8))"
        let email = "\(UUID().uuidString.prefix(8))@test.com"
        let password = "123456"

        var token: String = ""

        // Register
        try await app.test(.POST, "/api/auth/register", beforeRequest: { req in
            try req.content.encode([
                "username": username,
                "email": email,
                "password": password
            ])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let auth = try res.content.decode(AuthResponse.self)
            XCTAssertEqual(auth.user.username, username)
            XCTAssertEqual(auth.user.email, email)
            XCTAssertFalse(auth.token.isEmpty)
            token = auth.token
        })

        // Profile (protected)
        try await app.test(.GET, "/api/auth/profile", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let user = try res.content.decode(User.Public.self)
            XCTAssertEqual(user.username, username)
            XCTAssertEqual(user.email, email)
        })

        // Login
        try await app.test(.POST, "/api/auth/login", beforeRequest: { req in
            try req.content.encode([
                "email": email,
                "password": password
            ])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let auth = try res.content.decode(AuthResponse.self)
            XCTAssertFalse(auth.token.isEmpty)
        })
    }
}
