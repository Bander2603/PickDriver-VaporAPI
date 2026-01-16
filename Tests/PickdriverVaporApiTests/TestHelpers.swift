//
//  TestHelpers.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

// MARK: - App lifecycle helper (prevents async teardown races)

func withTestApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await TestApp.make()
    do {
        try await body(app)
        await TestApp.shutdown(app)
    } catch {
        await TestApp.shutdown(app)
        throw error
    }
}

// MARK: - Common API error type

struct APIErrorResponse: Content {
    var error: Bool?
    var reason: String
}

// MARK: - Auth helpers

enum TestAuth {
    struct CreatedUser {
        let username: String
        let email: String
        let password: String
        let token: String
        let publicUser: User.Public
    }

    /// Registers a new user through the real endpoint and returns token + user.
    static func register(
        app: Application,
        username: String? = nil,
        email: String? = nil,
        password: String = "123456"
    ) async throws -> CreatedUser {
        let u = username ?? "user_\(UUID().uuidString.prefix(8))"
        let e = email ?? "\(UUID().uuidString.prefix(8))@test.com"

        var token: String = ""
        var publicUser: User.Public?

        try await app.test(.POST, "/api/auth/register", beforeRequest: { req async throws in
            try req.content.encode([
                "username": u,
                "email": e,
                "password": password
            ])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let auth = try res.content.decode(AuthResponse.self)
            XCTAssertEqual(auth.user.username, u)
            XCTAssertEqual(auth.user.email, e)
            XCTAssertFalse(auth.token.isEmpty)
            token = auth.token
            publicUser = auth.user
        })

        return CreatedUser(
            username: u,
            email: e,
            password: password,
            token: token,
            publicUser: try XCTUnwrap(publicUser)
        )
    }

    static func login(app: Application, email: String, password: String) async throws -> AuthResponse {
        var authResponse: AuthResponse?
        try await app.test(.POST, "/api/auth/login", beforeRequest: { req async throws in
            try req.content.encode([
                "email": email,
                "password": password
            ])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            authResponse = try res.content.decode(AuthResponse.self)
        })
        return try XCTUnwrap(authResponse)
    }
}

// MARK: - Seed helpers (DB)

enum TestSeed {
    // MARK: Seasons

    static func createSeason(
        app: Application,
        year: Int = 2026,
        name: String = "Season \(Int.random(in: 2000...9999))",
        active: Bool = true
    ) async throws -> Season {
        let s = Season(year: year, name: name, active: active)
        try await s.save(on: app.db)
        return s
    }

    // MARK: f1_teams (seed via SQL)

    struct InsertedTeam {
        let id: Int
        let seasonID: Int
        let name: String
        let color: String
    }

    static func createF1Team(
        app: Application,
        seasonID: Int,
        name: String = "Team \(Int.random(in: 1...9999))",
        color: String = "#FFFFFF"
    ) async throws -> InsertedTeam {
        let sql = app.db as! (any SQLDatabase)

        struct IDRow: Decodable { let id: Int }

        let query: SQLQueryString = "INSERT INTO public.f1_teams (season_id, name, color) VALUES (\(bind: seasonID), \(bind: name), \(bind: color)) RETURNING id"
        let row = try await sql.raw(query).first(decoding: IDRow.self)

        let id = try XCTUnwrap(row?.id, "Failed to insert f1_team")
        return InsertedTeam(id: id, seasonID: seasonID, name: name, color: color)
    }

    // MARK: Races

    static func createRace(
        app: Application,
        seasonID: Int,
        round: Int,
        name: String,
        completed: Bool,
        sprint: Bool = false,
        fp1Time: Date? = nil,
        raceTime: Date? = nil
    ) async throws -> Race {
        let r = Race()
        r.seasonID = seasonID
        r.round = round
        r.name = name
        r.circuitName = "Test Circuit"
        r.circuitData = .init() // satisfy NOT NULL json column
        r.country = "Spain"
        r.countryCode = "ES"
        r.sprint = sprint
        r.completed = completed
        r.fp1Time = fp1Time
        r.raceTime = raceTime
        try await r.save(on: app.db)
        return r
    }

    // MARK: Drivers

    static func createDriver(
        app: Application,
        seasonID: Int,
        f1TeamID: Int,
        firstName: String = "Test",
        lastName: String = "Driver",
        driverNumber: Int = Int.random(in: 2...99),
        driverCode: String = "TST"
    ) async throws -> Driver {
        let d = Driver(
            seasonID: seasonID,
            teamID: f1TeamID,
            firstName: firstName,
            lastName: lastName,
            country: "Spain",
            driverNumber: driverNumber,
            active: true,
            driverCode: driverCode
        )
        try await d.save(on: app.db)
        return d
    }
}

