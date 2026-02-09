//
//  PickDriverVaultTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.02.26.
//

import XCTVapor
@testable import PickdriverVaporApi

final class PickDriverVaultTests: XCTestCase {
    private let internalToken = "test-internal-token"

    struct SystemInfoResponse: Content {
        let status: String
        let service: String
        let version: String
        let environment: String
        let timestamp: Date
        let uptimeSeconds: Int
        let recentMigrations: [MigrationInfo]

        struct MigrationInfo: Content {
            let name: String
            let batch: Int
            let createdAt: Date?
        }
    }

    struct SmokeResponse: Content {
        let status: String
        let timestamp: Date
        let checks: [Check]

        struct Check: Content {
            let name: String
            let status: String
            let details: String
        }
    }

    func testInternalInfoRequiresToken() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/system/info", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testInternalInfoReturnsMetadataWithValidToken() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/system/info", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(SystemInfoResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertEqual(payload.service, "pickdriver-vapor-api")
                XCTAssertEqual(payload.environment, "testing")
                XCTAssertFalse(payload.recentMigrations.isEmpty)
            })
        }
    }

    func testInternalSmokeFailsWhenNoActiveSeasonOrRaces() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/system/smoke", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .serviceUnavailable)
                let payload = try res.content.decode(SmokeResponse.self)
                XCTAssertEqual(payload.status, "fail")
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "active_season_exists" && $0.status == "fail" }))
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "race_catalog_available" && $0.status == "fail" }))
            })
        }
    }

    func testInternalSmokePassesWithSeededSeasonAndRace() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, active: true)
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Test GP",
                completed: false,
                raceTime: Date().addingTimeInterval(3600)
            )

            try await app.test(.GET, "/api/internal/system/smoke", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(SmokeResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertTrue(payload.checks.allSatisfy { $0.status == "ok" })
            })
        }
    }
}
