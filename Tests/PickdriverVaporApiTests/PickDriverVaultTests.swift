//
//  PickDriverVaultTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.02.26.
//

import XCTVapor
import SQLKit
import FluentPostgresDriver
@testable import PickdriverVaporApi

final class PickDriverVaultTests: XCTestCase {
    private let internalToken = "test-internal-token"

    private func registerDrillDatabase(on app: Application) {
        let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber
        let username = Environment.get("DATABASE_USERNAME") ?? "vapor_username"
        let password = Environment.get("DATABASE_PASSWORD") ?? "vapor_password"
        let dbName = Environment.get("DATABASE_NAME") ?? "vapor_database"
        let config = SQLPostgresConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: dbName,
            tls: .disable
        )
        app.databases.use(.postgres(configuration: config), as: .drill, isDefault: false)
    }

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

    struct DBInfoResponse: Content {
        let schemaVersion: String
        let lastMigrationAt: Date?
        let appliedMigrations: [MigrationInfo]
        let expectedCriticalTables: [String]
        let criticalTableCounts: [String: Int]?

        struct MigrationInfo: Content {
            let name: String
            let batch: Int
            let createdAt: Date?
        }
    }

    struct BackupValidateResponse: Content {
        let success: Bool
        let checks: [Check]
        let summary: Summary
        let validatedAtUtc: Date

        struct Check: Content {
            let name: String
            let status: String
            let details: String
            let latencyMs: Double?
        }

        struct Summary: Content {
            let passed: Int
            let failed: Int
            let warnings: Int
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

    func testInternalOpsDbInfoRequiresToken() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/ops/db-info", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testInternalOpsDbInfoReturnsSchemaMetadata() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/ops/db-info", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(DBInfoResponse.self)
                XCTAssertTrue(payload.schemaVersion.hasPrefix("fluent-"))
                XCTAssertFalse(payload.appliedMigrations.isEmpty)
                XCTAssertTrue(payload.expectedCriticalTables.contains("users"))
                XCTAssertTrue((payload.criticalTableCounts ?? [:]).keys.contains("users"))
            })
        }
    }

    func testInternalOpsDbInfoSupportsTargetDrill() async throws {
        try await withTestApp { app in
            registerDrillDatabase(on: app)

            try await app.test(.GET, "/api/internal/ops/db-info?target=drill", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(DBInfoResponse.self)
                XCTAssertTrue(payload.schemaVersion.hasPrefix("fluent-"))
            })
        }
    }

    func testInternalOpsDbInfoDrillFailsWhenDrillDatabaseIsNotConfigured() async throws {
        try await withTestApp { app in
            try await app.test(.GET, "/api/internal/ops/db-info?target=drill", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .serviceUnavailable)
                let payload = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(payload.reason.contains("Drill target is not configured"))
            })
        }
    }

    func testInternalBackupValidateQuickReturnsSuccessOnDrillTarget() async throws {
        try await withTestApp { app in
            registerDrillDatabase(on: app)

            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "drill",
                    "backupId": "backup-quick-001",
                    "checksProfile": "quick",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(BackupValidateResponse.self)
                XCTAssertTrue(payload.success)
                XCTAssertEqual(payload.summary.failed, 0)
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "critical_tables_presence" && $0.status == "ok" }))
            })
        }
    }

    func testInternalBackupValidateRejectsRestrictedProductionTarget() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "production",
                    "backupId": "backup-restricted-001",
                    "checksProfile": "quick",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })
        }
    }

    func testInternalBackupValidateRejectsUnknownTarget() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "unknown-target",
                    "backupId": "backup-unknown-001",
                    "checksProfile": "quick",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            })
        }
    }

    func testInternalBackupValidateDrillFailsWhenDrillDatabaseIsNotConfigured() async throws {
        try await withTestApp { app in
            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "drill",
                    "backupId": "backup-drill-missing-001",
                    "checksProfile": "quick",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .serviceUnavailable)
                let payload = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(payload.reason.contains("Drill target is not configured"))
            })
        }
    }

    func testInternalBackupValidateFullFailsWithoutSeedDataOnDrillTarget() async throws {
        try await withTestApp { app in
            registerDrillDatabase(on: app)

            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "drill",
                    "backupId": "backup-full-empty-001",
                    "checksProfile": "full",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(BackupValidateResponse.self)
                XCTAssertFalse(payload.success)
                XCTAssertGreaterThan(payload.summary.failed, 0)
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "active_season_exists" && $0.status == "fail" }))
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "race_catalog_available" && $0.status == "fail" }))
            })
        }
    }

    func testInternalBackupValidateFullPassesWithSeededSeasonAndRaceOnDrillTarget() async throws {
        try await withTestApp { app in
            registerDrillDatabase(on: app)
            let drillDB = app.db(.drill)

            let season = Season(year: 2026, name: "Drill Season", active: true)
            try await season.save(on: drillDB)

            let race = Race()
            race.seasonID = try season.requireID()
            race.round = 1
            race.name = "Drill Validation GP"
            race.circuitName = "Drill Circuit"
            race.circuitData = .init()
            race.country = "Spain"
            race.countryCode = "ES"
            race.sprint = false
            race.completed = false
            race.raceTime = Date().addingTimeInterval(3600)
            try await race.save(on: drillDB)

            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "drill",
                    "backupId": "backup-full-seeded-001",
                    "checksProfile": "full",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let payload = try res.content.decode(BackupValidateResponse.self)
                XCTAssertTrue(payload.success)
                XCTAssertEqual(payload.summary.failed, 0)
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "active_season_exists" && $0.status == "ok" }))
                XCTAssertTrue(payload.checks.contains(where: { $0.name == "race_catalog_available" && $0.status == "ok" }))
            })
        }
    }

    func testInternalBackupValidateWritesDrillAuditEventsWithMetadata() async throws {
        try await withTestApp { app in
            registerDrillDatabase(on: app)

            try await app.test(.POST, "/api/internal/ops/backup/validate", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                try req.content.encode([
                    "target": "drill",
                    "backupId": "backup-audit-001",
                    "checksProfile": "quick",
                    "source": "vault-tests"
                ])
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

            let sql = app.db as! (any SQLDatabase)
            struct CountRow: Decodable { let count: Int }
            let drillStarted = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.ops_audit_events
                WHERE event_type = 'drill_started'
            """).first(decoding: CountRow.self)
            let restoreCompleted = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.ops_audit_events
                WHERE event_type = 'restore_completed'
            """).first(decoding: CountRow.self)
            let drillFinished = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.ops_audit_events
                WHERE event_type = 'drill_finished'
            """).first(decoding: CountRow.self)
            struct MetadataRow: Decodable {
                let backupID: String?
                let target: String?
                let source: String

                enum CodingKeys: String, CodingKey {
                    case backupID = "backup_id"
                    case target
                    case source
                }
            }
            let metadataRow = try await sql.raw("""
                SELECT
                    metadata->>'backupId' AS backup_id,
                    metadata->>'target' AS target,
                    source
                FROM public.ops_audit_events
                WHERE event_type = 'drill_started'
                ORDER BY id DESC
                LIMIT 1
            """).first(decoding: MetadataRow.self)

            XCTAssertGreaterThanOrEqual(drillStarted?.count ?? 0, 1)
            XCTAssertGreaterThanOrEqual(restoreCompleted?.count ?? 0, 1)
            XCTAssertGreaterThanOrEqual(drillFinished?.count ?? 0, 1)
            XCTAssertEqual(metadataRow?.backupID, "backup-audit-001")
            XCTAssertEqual(metadataRow?.target, "drill")
            XCTAssertEqual(metadataRow?.source, "vault-tests")
        }
    }

    func testInternalRoutesRequireHTTPSWhenEnabled() async throws {
        try await withTestApp { app in
            app.internalRoutesRequireHTTPS = true

            try await app.test(.GET, "/api/internal/system/info", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .forbidden)
            })

            try await app.test(.GET, "/api/internal/system/info", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
                req.headers.replaceOrAdd(name: "X-Forwarded-Proto", value: "https")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }
}
