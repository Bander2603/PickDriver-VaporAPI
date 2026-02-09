import Vapor
import Fluent
import SQLKit

struct InternalSystemController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("info", use: info)
        routes.get("smoke", use: smoke)
        let maintenance = routes.grouped("maintenance")
        maintenance.post("enable", use: enableMaintenance)
        maintenance.post("disable", use: disableMaintenance)
    }

    struct MigrationInfo: Content {
        let name: String
        let batch: Int
        let createdAt: Date?
    }

    struct SystemInfoResponse: Content {
        let status: String
        let service: String
        let version: String
        let environment: String
        let timestamp: Date
        let uptimeSeconds: Int
        let recentMigrations: [MigrationInfo]
    }

    struct SmokeCheck: Content {
        let name: String
        let status: String
        let details: String
    }

    struct SmokeResponse: Content {
        let status: String
        let timestamp: Date
        let checks: [SmokeCheck]
    }

    struct MaintenanceModeRequest: Content {
        let source: String?
        let reason: String?
    }

    struct MaintenanceModeResponse: Content {
        let status: String
        let maintenanceMode: Bool
        let changed: Bool
        let eventType: String
        let auditLogged: Bool
        let timestamp: Date
    }

    func info(_ req: Request) async throws -> SystemInfoResponse {
        let migrations = try await recentMigrations(on: req)
        return SystemInfoResponse(
            status: "ok",
            service: "pickdriver-vapor-api",
            version: req.application.appVersion,
            environment: req.application.environment.name,
            timestamp: Date(),
            uptimeSeconds: uptimeSeconds(from: req),
            recentMigrations: migrations
        )
    }

    func smoke(_ req: Request) async throws -> Response {
        var checks: [SmokeCheck] = []
        var healthy = true

        // Check 1: DB connection + latency
        do {
            let latency = try await pingDatabase(on: req)
            checks.append(.init(
                name: "database_connection",
                status: "ok",
                details: "Database reachable (\(latency) ms)."
            ))
        } catch {
            healthy = false
            checks.append(.init(
                name: "database_connection",
                status: "fail",
                details: (error as? any AbortError)?.reason ?? "Database connectivity check failed."
            ))
        }

        // Check 2: Active season exists
        do {
            let activeSeasons = try await Season.query(on: req.db)
                .filter(\.$active == true)
                .count()
            if activeSeasons > 0 {
                checks.append(.init(
                    name: "active_season_exists",
                    status: "ok",
                    details: "Active seasons: \(activeSeasons)."
                ))
            } else {
                healthy = false
                checks.append(.init(
                    name: "active_season_exists",
                    status: "fail",
                    details: "No active season found."
                ))
            }
        } catch {
            healthy = false
            checks.append(.init(
                name: "active_season_exists",
                status: "fail",
                details: "Failed to query seasons."
            ))
        }

        // Check 3: Race catalog available
        do {
            let raceCount = try await Race.query(on: req.db).count()
            if raceCount > 0 {
                checks.append(.init(
                    name: "race_catalog_available",
                    status: "ok",
                    details: "Races: \(raceCount)."
                ))
            } else {
                healthy = false
                checks.append(.init(
                    name: "race_catalog_available",
                    status: "fail",
                    details: "No races found."
                ))
            }
        } catch {
            healthy = false
            checks.append(.init(
                name: "race_catalog_available",
                status: "fail",
                details: "Failed to query races."
            ))
        }

        // Check 4: Fluent migration history
        do {
            let migrationCount = try await migrationHistoryCount(on: req)
            if migrationCount > 0 {
                checks.append(.init(
                    name: "migration_history_available",
                    status: "ok",
                    details: "Migration rows: \(migrationCount)."
                ))
            } else {
                healthy = false
                checks.append(.init(
                    name: "migration_history_available",
                    status: "fail",
                    details: "No migration rows found in _fluent_migrations."
                ))
            }
        } catch {
            healthy = false
            checks.append(.init(
                name: "migration_history_available",
                status: "fail",
                details: "Failed to query migration history."
            ))
        }

        let response = SmokeResponse(
            status: healthy ? "ok" : "fail",
            timestamp: Date(),
            checks: checks
        )
        let http = Response(status: healthy ? .ok : .serviceUnavailable)
        try http.content.encode(response)
        return http
    }

    func enableMaintenance(_ req: Request) async throws -> MaintenanceModeResponse {
        let payload = try? req.content.decode(MaintenanceModeRequest.self)
        let source = sanitizeSource(payload?.source)
        let previous = req.application.maintenanceMode
        req.application.maintenanceMode = true
        let changed = previous == false

        let eventType = changed ? "maintenance_enabled" : "maintenance_enable_noop"
        let auditLogged = await logOpsEvent(
            on: req,
            eventType: eventType,
            source: source,
            reason: payload?.reason,
            previousMaintenanceMode: previous,
            currentMaintenanceMode: true
        )

        return MaintenanceModeResponse(
            status: "ok",
            maintenanceMode: true,
            changed: changed,
            eventType: eventType,
            auditLogged: auditLogged,
            timestamp: Date()
        )
    }

    func disableMaintenance(_ req: Request) async throws -> MaintenanceModeResponse {
        let payload = try? req.content.decode(MaintenanceModeRequest.self)
        let source = sanitizeSource(payload?.source)
        let previous = req.application.maintenanceMode
        req.application.maintenanceMode = false
        let changed = previous == true

        let eventType = changed ? "maintenance_disabled" : "maintenance_disable_noop"
        let auditLogged = await logOpsEvent(
            on: req,
            eventType: eventType,
            source: source,
            reason: payload?.reason,
            previousMaintenanceMode: previous,
            currentMaintenanceMode: false
        )

        return MaintenanceModeResponse(
            status: "ok",
            maintenanceMode: false,
            changed: changed,
            eventType: eventType,
            auditLogged: auditLogged,
            timestamp: Date()
        )
    }

    private func uptimeSeconds(from req: Request) -> Int {
        max(0, Int(Date().timeIntervalSince(req.application.startedAt)))
    }

    private func pingDatabase(on req: Request) async throws -> Double {
        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.serviceUnavailable, reason: "SQL database is unavailable.")
        }

        struct Row: Decodable {
            let one: Int
        }

        let start = Date()
        _ = try await sql.raw("SELECT 1 AS one").first(decoding: Row.self)
        return Date().timeIntervalSince(start) * 1000
    }

    private func recentMigrations(on req: Request) async throws -> [MigrationInfo] {
        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.serviceUnavailable, reason: "SQL database is unavailable.")
        }

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
            ORDER BY created_at DESC
            LIMIT 20
        """).all(decoding: Row.self)

        return rows.map {
            MigrationInfo(name: $0.name, batch: $0.batch, createdAt: $0.createdAt)
        }
    }

    private func migrationHistoryCount(on req: Request) async throws -> Int {
        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.serviceUnavailable, reason: "SQL database is unavailable.")
        }

        struct CountRow: Decodable {
            let count: Int
        }

        let row = try await sql.raw("""
            SELECT COUNT(*)::int AS count
            FROM public._fluent_migrations
        """).first(decoding: CountRow.self)

        return row?.count ?? 0
    }

    private func sanitizeSource(_ source: String?) -> String {
        guard let source = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            return "manual"
        }
        return String(source.prefix(64))
    }

    private func logOpsEvent(
        on req: Request,
        eventType: String,
        source: String,
        reason: String?,
        previousMaintenanceMode: Bool,
        currentMaintenanceMode: Bool
    ) async -> Bool {
        guard let sql = req.db as? (any SQLDatabase) else {
            req.logger.warning("Ops audit skipped: SQLDatabase unavailable.")
            return false
        }

        struct Metadata: Encodable {
            let reason: String?
            let previousMaintenanceMode: Bool
            let currentMaintenanceMode: Bool
            let path: String
            let method: String
        }

        let metadata = Metadata(
            reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            previousMaintenanceMode: previousMaintenanceMode,
            currentMaintenanceMode: currentMaintenanceMode,
            path: req.url.path,
            method: req.method.rawValue
        )
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
