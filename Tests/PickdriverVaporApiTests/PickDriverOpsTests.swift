//
//  PickDriverOpsTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.02.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class PickDriverOpsTests: XCTestCase {
    private let internalToken = "test-internal-token"

    struct LiveResponse: Content {
        let status: String
        let service: String
        let version: String
        let uptimeSeconds: Int
        let timestamp: Date
    }

    struct ReadyResponse: Content {
        let status: String
        let timestamp: Date
        let checks: [Check]

        struct Check: Content {
            let name: String
            let status: String
            let latencyMs: Double?
            let reason: String?
        }
    }

    struct PingResponse: Content {
        let status: String
        let serverTime: Date
        let uptimeSeconds: Int
        let dbStatus: String
        let dbLatencyMs: Double?
    }

    struct DependenciesResponse: Content {
        let status: String
        let timestamp: Date
        let maintenanceMode: Bool
        let dependencies: [Dependency]

        struct Dependency: Content {
            let name: String
            let status: String
            let latencyMs: Double?
            let details: String
        }
    }

    struct MaintenanceModeResponse: Content {
        let status: String
        let maintenanceMode: Bool
        let changed: Bool
        let eventType: String
        let auditLogged: Bool
        let timestamp: Date
    }

    func testHealthLiveReturnsOK() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/health/live", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(LiveResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertEqual(payload.service, "pickdriver-vapor-api")
                XCTAssertGreaterThanOrEqual(payload.uptimeSeconds, 0)
            })
        }
    }

    func testHealthReadyReturnsOKWhenDatabaseIsReachable() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/health/ready", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(ReadyResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertEqual(payload.checks.first?.name, "database")
                XCTAssertEqual(payload.checks.first?.status, "ok")
            })
        }
    }

    func testHealthPingReturnsDatabaseLatency() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/health/ping", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(PingResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertEqual(payload.dbStatus, "ok")
                XCTAssertNotNil(payload.dbLatencyMs)
            })
        }
    }

    func testHealthDependenciesReturnsDependencyDetails() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/health/dependencies", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(DependenciesResponse.self)
                XCTAssertEqual(payload.status, "ok")
                XCTAssertTrue(payload.dependencies.contains(where: { $0.name == "database" && $0.status == "ok" }))
                XCTAssertTrue(payload.dependencies.contains(where: { $0.name == "draft_deadline_task" && $0.status == "skip" }))
            })
        }
    }

    func testMaintenanceEndpointsRequireInternalToken() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/system/maintenance/enable", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testEnableMaintenanceBlocksPublicApiAndDisableRestoresAccess() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/system/maintenance/enable", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode(["source": "ops-tests", "reason": "maintenance test"])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(MaintenanceModeResponse.self)
                XCTAssertEqual(payload.maintenanceMode, true)
            })

            try await app.test(.GET, "/api/drivers", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .serviceUnavailable)
            })

            try await app.test(.GET, "/api/health/live", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            try await app.test(.POST, "/api/internal/system/maintenance/disable", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode(["source": "ops-tests", "reason": "maintenance test done"])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(MaintenanceModeResponse.self)
                XCTAssertEqual(payload.maintenanceMode, false)
            })

            try await app.test(.GET, "/api/drivers", afterResponse: { res async throws in
                XCTAssertNotEqual(res.status, .serviceUnavailable)
            })
        }
    }

    func testMaintenanceChangesAreWrittenToOpsAuditEvents() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/system/maintenance/enable", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode(["source": "ops-tests"])
            }, afterResponse: { _ async throws in })

            try await app.test(.POST, "/api/internal/system/maintenance/disable", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode(["source": "ops-tests"])
            }, afterResponse: { _ async throws in })

            let sql = app.db as! (any SQLDatabase)
            struct CountRow: Decodable { let count: Int }

            let enabled = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.ops_audit_events
                WHERE event_type = 'maintenance_enabled'
            """).first(decoding: CountRow.self)

            let disabled = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.ops_audit_events
                WHERE event_type = 'maintenance_disabled'
            """).first(decoding: CountRow.self)

            XCTAssertGreaterThanOrEqual(enabled?.count ?? 0, 1)
            XCTAssertGreaterThanOrEqual(disabled?.count ?? 0, 1)
        }
    }
}
