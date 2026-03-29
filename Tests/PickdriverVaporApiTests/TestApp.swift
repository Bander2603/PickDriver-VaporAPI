//
//  TestApp.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 10.01.26.
//

import XCTVapor
@testable import PickdriverVaporApi
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum TestApp {
    static func make() async throws -> Application {
        // Force UTC during tests because the schema still uses `timestamp without time zone`.
        setenv("TZ", "UTC", 1)
        tzset()

        let env = Environment.testing
        let app = try await Application.make(env)

        // Safety guard: never hit prod
        let dbName = Environment.get("DATABASE_NAME") ?? ""
        precondition(dbName.lowercased().contains("test"),
                     "DATABASE_NAME must be a test database. Current: \(dbName)")

        // Configure app (DB/JWT/routes/migrations registration)
        try await configure(app)

        // Create schema in test DB
        try await app.autoMigrate()

        return app
    }

    static func shutdown(_ app: Application) async {
        // Optional: clean DB to keep tests deterministic
        try? await app.autoRevert()
        try? await app.asyncShutdown()
    }
}
