import Vapor
import Fluent
import SQLKit

struct InternalOpsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("db-info", use: dbInfo)
        routes.grouped("backup").post("validate", use: validateBackup)
    }

    private let expectedCriticalTables: [String] = [
        "users",
        "seasons",
        "f1_teams",
        "drivers",
        "races",
        "leagues",
        "league_members",
        "league_teams",
        "team_members",
        "race_drafts",
        "player_picks",
        "player_bans",
        "push_tokens",
        "push_notifications",
        "ops_audit_events"
    ]

    struct AppliedMigration: Content {
        let name: String
        let batch: Int
        let createdAt: Date?
    }

    struct DBInfoResponse: Content {
        let schemaVersion: String
        let lastMigrationAt: Date?
        let appliedMigrations: [AppliedMigration]
        let expectedCriticalTables: [String]
        let criticalTableCounts: [String: Int]?
    }

    enum ChecksProfile: String, Content {
        case quick
        case full
    }

    struct BackupValidateRequest: Content {
        let target: String
        let backupId: String
        let checksProfile: ChecksProfile?
        let source: String?
        let reason: String?
    }

    struct BackupCheck: Content {
        let name: String
        let status: String
        let details: String
        let latencyMs: Double?
    }

    struct BackupSummary: Content {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    struct BackupValidateResponse: Content {
        let success: Bool
        let checks: [BackupCheck]
        let summary: BackupSummary
        let validatedAtUtc: Date
    }

    struct DBInfoQuery: Content {
        let target: String?
    }

    private enum ResolvedTarget: String {
        case primary
        case drill

        var responseLabel: String {
            switch self {
            case .primary: return "staging"
            case .drill: return "drill"
            }
        }
    }

    func dbInfo(_ req: Request) async throws -> DBInfoResponse {
        let query = try req.query.decode(DBInfoQuery.self)
        let target = try resolveTarget(query.target, defaultTarget: .primary)
        let sql = try resolveSQLDatabase(for: target, on: req)

        let fingerprint = try await migrationFingerprint(on: sql)
        let migrations = try await recentMigrations(on: sql, limit: 50)
        let present = try await criticalTablePresence(on: sql, tables: expectedCriticalTables)
        let counts = try await criticalTableCounts(on: sql, presentTables: present)

        return DBInfoResponse(
            schemaVersion: fingerprint.schemaVersion,
            lastMigrationAt: fingerprint.lastMigrationAt,
            appliedMigrations: migrations,
            expectedCriticalTables: expectedCriticalTables,
            criticalTableCounts: counts.isEmpty ? nil : counts
        )
    }

    func validateBackup(_ req: Request) async throws -> BackupValidateResponse {
        let payload = try req.content.decode(BackupValidateRequest.self)
        let target = try resolveTarget(try requiredField(payload.target, fieldName: "target"), defaultTarget: .primary)
        let sql = try resolveSQLDatabase(for: target, on: req)
        let backupID = try requiredField(payload.backupId, fieldName: "backupId")
        let profile = payload.checksProfile ?? .quick
        let source = sanitizeSource(payload.source)
        let reason = payload.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let validationStart = Date()

        struct DrillMetadata: Encodable {
            let target: String
            let backupId: String
            let checksProfile: String
            let reason: String?
            let requestPath: String
            let requestMethod: String
            let validatedAtUtc: Date?
            let success: Bool?
            let summary: BackupSummary?
        }

        let sharedMetadata = DrillMetadata(
            target: target.responseLabel,
            backupId: backupID,
            checksProfile: profile.rawValue,
            reason: reason,
            requestPath: req.url.path,
            requestMethod: req.method.rawValue,
            validatedAtUtc: nil,
            success: nil,
            summary: nil
        )

        _ = await logOpsEvent(on: req, eventType: "drill_started", source: source, metadata: sharedMetadata)
        _ = await logOpsEvent(on: req, eventType: "restore_completed", source: source, metadata: sharedMetadata)

        var checks: [BackupCheck] = []
        var passed = 0
        var failed = 0
        var warnings = 0

        func appendCheck(_ check: BackupCheck) {
            checks.append(check)
            switch check.status {
            case "ok":
                passed += 1
            case "fail":
                failed += 1
            case "warn":
                warnings += 1
            default:
                warnings += 1
            }
        }

        do {
            let latency = try await pingDatabase(on: sql)
            appendCheck(.init(
                name: "db-connectivity",
                status: "ok",
                details: "\(target.responseLabel) database reachable.",
                latencyMs: latency
            ))
        } catch {
            appendCheck(.init(
                name: "db-connectivity",
                status: "fail",
                details: "\(target.responseLabel) database connectivity check failed.",
                latencyMs: nil
            ))
        }

        do {
            let migrationCount = try await migrationHistoryCount(on: sql)
            if migrationCount > 0 {
                appendCheck(.init(
                    name: "migration_history_available",
                    status: "ok",
                    details: "Migration rows: \(migrationCount).",
                    latencyMs: nil
                ))
            } else {
                appendCheck(.init(
                    name: "migration_history_available",
                    status: "fail",
                    details: "No migration rows found in _fluent_migrations.",
                    latencyMs: nil
                ))
            }
        } catch {
            appendCheck(.init(
                name: "migration_history_available",
                status: "fail",
                details: "Failed to query migration history.",
                latencyMs: nil
            ))
        }

        do {
            let start = Date()
            let presence = try await criticalTablePresence(on: sql, tables: expectedCriticalTables)
            let missing = expectedCriticalTables.filter { presence[$0] != true }
            let latency = Date().timeIntervalSince(start) * 1000

            if missing.isEmpty {
                appendCheck(.init(
                    name: "critical_tables_presence",
                    status: "ok",
                    details: "All critical tables are present.",
                    latencyMs: latency
                ))
            } else {
                appendCheck(.init(
                    name: "critical_tables_presence",
                    status: "fail",
                    details: "Missing critical tables: \(missing.joined(separator: ", ")).",
                    latencyMs: latency
                ))
            }

            if profile == .full {
                let counts = try await criticalTableCounts(on: sql, presentTables: presence)
                let zeroCountTables = counts.filter { $0.value == 0 }.map(\.key).sorted()
                if zeroCountTables.isEmpty {
                    appendCheck(.init(
                        name: "critical_table_counts",
                        status: "ok",
                        details: "All critical tables contain rows.",
                        latencyMs: nil
                    ))
                } else {
                    appendCheck(.init(
                        name: "critical_table_counts",
                        status: "warn",
                        details: "Critical tables with zero rows: \(zeroCountTables.joined(separator: ", ")).",
                        latencyMs: nil
                    ))
                }
            }
        } catch {
            appendCheck(.init(
                name: "critical_tables_presence",
                status: "fail",
                details: "Failed to inspect critical tables.",
                latencyMs: nil
            ))
        }

        if profile == .full {
            do {
                let activeSeasons = try await countRows(on: sql, sql: """
                    SELECT COUNT(*)::int AS count
                    FROM public.seasons
                    WHERE active = true
                """)
                if activeSeasons > 0 {
                    appendCheck(.init(
                        name: "active_season_exists",
                        status: "ok",
                        details: "Active seasons: \(activeSeasons).",
                        latencyMs: nil
                    ))
                } else {
                    appendCheck(.init(
                        name: "active_season_exists",
                        status: "fail",
                        details: "No active season found.",
                        latencyMs: nil
                    ))
                }
            } catch {
                appendCheck(.init(
                    name: "active_season_exists",
                    status: "fail",
                    details: "Failed to query seasons.",
                    latencyMs: nil
                ))
            }

            do {
                let raceCount = try await countRows(on: sql, sql: """
                    SELECT COUNT(*)::int AS count
                    FROM public.races
                """)
                if raceCount > 0 {
                    appendCheck(.init(
                        name: "race_catalog_available",
                        status: "ok",
                        details: "Races: \(raceCount).",
                        latencyMs: nil
                    ))
                } else {
                    appendCheck(.init(
                        name: "race_catalog_available",
                        status: "fail",
                        details: "No races found.",
                        latencyMs: nil
                    ))
                }
            } catch {
                appendCheck(.init(
                    name: "race_catalog_available",
                    status: "fail",
                    details: "Failed to query races.",
                    latencyMs: nil
                ))
            }
        }

        let summary = BackupSummary(passed: passed, failed: failed, warnings: warnings)
        let success = summary.failed == 0
        let validatedAt = Date()
        let finalMetadata = DrillMetadata(
            target: target.responseLabel,
            backupId: backupID,
            checksProfile: profile.rawValue,
            reason: reason,
            requestPath: req.url.path,
            requestMethod: req.method.rawValue,
            validatedAtUtc: validatedAt,
            success: success,
            summary: summary
        )

        let validationEventType = success ? "functional_validation_completed" : "functional_validation_failed"
        _ = await logOpsEvent(on: req, eventType: validationEventType, source: source, metadata: finalMetadata)
        _ = await logOpsEvent(on: req, eventType: "drill_finished", source: source, metadata: finalMetadata)

        req.logger.info(
            "Backup validation completed",
            metadata: [
                "target": .string(target.responseLabel),
                "backup_id": .string(backupID),
                "checks_profile": .string(profile.rawValue),
                "success": .stringConvertible(success),
                "duration_ms": .stringConvertible(Int(Date().timeIntervalSince(validationStart) * 1000))
            ]
        )

        return BackupValidateResponse(
            success: success,
            checks: checks,
            summary: summary,
            validatedAtUtc: validatedAt
        )
    }

    private func resolveTarget(_ raw: String?, defaultTarget: ResolvedTarget) throws -> ResolvedTarget {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty else {
            return defaultTarget
        }

        switch normalized {
        case "drill":
            return .drill
        case "staging", "stage", "test", "default", "primary":
            return .primary
        case "prod", "production", "main", "live":
            throw Abort(.forbidden, reason: "Target '\(normalized)' is restricted for internal drill operations.")
        default:
            throw Abort(.badRequest, reason: "Unsupported target '\(normalized)'. Allowed values: drill, staging.")
        }
    }

    private func resolveSQLDatabase(for target: ResolvedTarget, on req: Request) throws -> any SQLDatabase {
        let database: any Database
        switch target {
        case .primary:
            database = req.db
        case .drill:
            guard req.application.databases.configuration(for: .drill) != nil else {
                throw Abort(
                    .serviceUnavailable,
                    reason: "Drill target is not configured. Define DRILL_DB_HOST, DRILL_DB_NAME, DRILL_DB_USER/DRILL_DB_USERNAME, and DRILL_DB_PASSWORD."
                )
            }
            database = req.db(.drill)
        }

        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.serviceUnavailable, reason: "SQL database is unavailable for target '\(target.responseLabel)'.")
        }
        return sql
    }

    private struct MigrationFingerprint {
        let schemaVersion: String
        let lastMigrationAt: Date?
    }

    private func migrationFingerprint(on sql: any SQLDatabase) async throws -> MigrationFingerprint {
        struct Row: Decodable {
            let schemaVersion: String
            let migrationCount: Int
            let maxBatch: Int
            let lastMigrationAt: Date?

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case migrationCount = "migration_count"
                case maxBatch = "max_batch"
                case lastMigrationAt = "last_migration_at"
            }
        }

        let row = try await sql.raw("""
            SELECT
                COALESCE(md5(string_agg(name || ':' || batch::text, ',' ORDER BY name, batch)), 'empty') AS schema_version,
                COUNT(*)::int AS migration_count,
                COALESCE(MAX(batch), 0)::int AS max_batch,
                MAX(created_at) AS last_migration_at
            FROM public._fluent_migrations
        """).first(decoding: Row.self)

        let schemaVersion = "fluent-\(row?.schemaVersion ?? "empty")-b\(row?.maxBatch ?? 0)-n\(row?.migrationCount ?? 0)"
        return MigrationFingerprint(schemaVersion: schemaVersion, lastMigrationAt: row?.lastMigrationAt)
    }

    private func recentMigrations(on sql: any SQLDatabase, limit: Int) async throws -> [AppliedMigration] {
        struct Row: Decodable {
            let name: String
            let batch: Int
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case name
                case batch
                case createdAt = "created_at"
            }
        }

        let rows = try await sql.raw("""
            SELECT name, batch, created_at
            FROM public._fluent_migrations
            ORDER BY created_at DESC NULLS LAST, batch DESC, name DESC
            LIMIT \(bind: max(1, limit))
        """).all(decoding: Row.self)

        return rows.map {
            AppliedMigration(name: $0.name, batch: $0.batch, createdAt: $0.createdAt)
        }
    }

    private func migrationHistoryCount(on sql: any SQLDatabase) async throws -> Int {
        struct CountRow: Decodable {
            let count: Int
        }

        let row = try await sql.raw("""
            SELECT COUNT(*)::int AS count
            FROM public._fluent_migrations
        """).first(decoding: CountRow.self)

        return row?.count ?? 0
    }

    private func criticalTablePresence(on sql: any SQLDatabase, tables: [String]) async throws -> [String: Bool] {
        struct PresenceRow: Decodable {
            let exists: Bool
        }

        var result: [String: Bool] = [:]
        for table in tables {
            let row = try await sql.raw("""
                SELECT to_regclass(\(bind: "public.\(table)")) IS NOT NULL AS exists
            """).first(decoding: PresenceRow.self)
            result[table] = row?.exists ?? false
        }
        return result
    }

    private func criticalTableCounts(on sql: any SQLDatabase, presentTables: [String: Bool]) async throws -> [String: Int] {
        struct CountRow: Decodable {
            let count: Int
        }

        var counts: [String: Int] = [:]
        for table in expectedCriticalTables where presentTables[table] == true {
            guard table.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil else {
                continue
            }
            let row = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM public.\(unsafeRaw: table)
            """).first(decoding: CountRow.self)
            counts[table] = row?.count ?? 0
        }
        return counts
    }

    private func pingDatabase(on sql: any SQLDatabase) async throws -> Double {
        struct Row: Decodable {
            let one: Int
        }

        let start = Date()
        _ = try await sql.raw("SELECT 1 AS one").first(decoding: Row.self)
        return Date().timeIntervalSince(start) * 1000
    }

    private func countRows(on sql: any SQLDatabase, sql query: SQLQueryString) async throws -> Int {
        struct Row: Decodable {
            let count: Int
        }

        let row = try await sql.raw(query).first(decoding: Row.self)
        return row?.count ?? 0
    }

    private func requiredField(_ value: String, fieldName: String) throws -> String {
        guard let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw Abort(.badRequest, reason: "Field '\(fieldName)' is required.")
        }
        return normalized
    }

    private func sanitizeSource(_ source: String?) -> String {
        guard let source = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            return "vault-worker"
        }
        return String(source.prefix(64))
    }

    private func logOpsEvent<Metadata: Encodable>(
        on req: Request,
        eventType: String,
        source: String,
        metadata: Metadata
    ) async -> Bool {
        guard let sql = req.db as? (any SQLDatabase) else {
            req.logger.warning("Ops audit skipped: SQLDatabase unavailable.")
            return false
        }

        do {
            let metadataJSON = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "{}"
            try await sql.raw("""
                INSERT INTO public.ops_audit_events (event_type, source, metadata)
                VALUES (\(bind: eventType), \(bind: source), \(bind: metadataJSON)::jsonb)
            """).run()
            return true
        } catch {
            req.logger.warning(
                "Ops audit insert failed",
                metadata: [
                    "event_type": .string(eventType),
                    "source": .string(source),
                    "error": .string(String(describing: error))
                ]
            )
            return false
        }
    }
}

private extension String {
    var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
