import Vapor
import SQLKit

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let health = routes.grouped("health")
        health.get("live", use: live)
        health.get("ready", use: ready)
        health.get("ping", use: ping)
        health.get("dependencies", use: dependencies)
    }

    struct LiveResponse: Content {
        let status: String
        let service: String
        let version: String
        let uptimeSeconds: Int
        let timestamp: Date
    }

    struct HealthCheck: Content {
        let name: String
        let status: String
        let latencyMs: Double?
        let reason: String?
    }

    struct ReadyResponse: Content {
        let status: String
        let timestamp: Date
        let checks: [HealthCheck]
    }

    struct PingResponse: Content {
        let status: String
        let serverTime: Date
        let uptimeSeconds: Int
        let dbStatus: String
        let dbLatencyMs: Double?
    }

    struct DependencyStatus: Content {
        let name: String
        let status: String
        let latencyMs: Double?
        let details: String
    }

    struct DependenciesResponse: Content {
        let status: String
        let timestamp: Date
        let maintenanceMode: Bool
        let dependencies: [DependencyStatus]
    }

    func live(_ req: Request) async throws -> LiveResponse {
        LiveResponse(
            status: "ok",
            service: "pickdriver-vapor-api",
            version: req.application.appVersion,
            uptimeSeconds: uptimeSeconds(from: req),
            timestamp: Date()
        )
    }

    func ready(_ req: Request) async throws -> Response {
        let response: ReadyResponse
        let status: HTTPResponseStatus

        do {
            let latency = try await pingDatabase(on: req)
            response = ReadyResponse(
                status: "ok",
                timestamp: Date(),
                checks: [
                    .init(name: "database", status: "ok", latencyMs: latency, reason: nil)
                ]
            )
            status = .ok
        } catch {
            let reason = (error as? any AbortError)?.reason ?? "Database health check failed."
            response = ReadyResponse(
                status: "fail",
                timestamp: Date(),
                checks: [
                    .init(name: "database", status: "fail", latencyMs: nil, reason: reason)
                ]
            )
            status = .serviceUnavailable
        }

        let http = Response(status: status)
        try http.content.encode(response)
        return http
    }

    func ping(_ req: Request) async throws -> PingResponse {
        do {
            let latency = try await pingDatabase(on: req)
            return PingResponse(
                status: "ok",
                serverTime: Date(),
                uptimeSeconds: uptimeSeconds(from: req),
                dbStatus: "ok",
                dbLatencyMs: latency
            )
        } catch {
            return PingResponse(
                status: "ok",
                serverTime: Date(),
                uptimeSeconds: uptimeSeconds(from: req),
                dbStatus: "fail",
                dbLatencyMs: nil
            )
        }
    }

    func dependencies(_ req: Request) async throws -> Response {
        var dependencies: [DependencyStatus] = []
        var hasFail = false

        do {
            let latency = try await pingDatabase(on: req)
            dependencies.append(.init(
                name: "database",
                status: "ok",
                latencyMs: latency,
                details: "Database reachable."
            ))
        } catch {
            hasFail = true
            dependencies.append(.init(
                name: "database",
                status: "fail",
                latencyMs: nil,
                details: (error as? any AbortError)?.reason ?? "Database check failed."
            ))
        }

        if req.application.environment == .testing {
            dependencies.append(.init(
                name: "draft_deadline_task",
                status: "skip",
                latencyMs: nil,
                details: "Not scheduled in testing environment."
            ))
        } else if req.application.draftDeadlineTask != nil {
            dependencies.append(.init(
                name: "draft_deadline_task",
                status: "ok",
                latencyMs: nil,
                details: "Background task is scheduled."
            ))
        } else {
            hasFail = true
            dependencies.append(.init(
                name: "draft_deadline_task",
                status: "fail",
                latencyMs: nil,
                details: "Background task is not scheduled."
            ))
        }

        if req.application.enableInternalRoutes {
            if let token = req.application.internalServiceToken, !token.isEmpty {
                dependencies.append(.init(
                    name: "internal_service_auth",
                    status: "ok",
                    latencyMs: nil,
                    details: "Internal service token is configured."
                ))
            } else {
                hasFail = true
                dependencies.append(.init(
                    name: "internal_service_auth",
                    status: "fail",
                    latencyMs: nil,
                    details: "Internal service token is missing."
                ))
            }
        } else {
            dependencies.append(.init(
                name: "internal_service_auth",
                status: "warn",
                latencyMs: nil,
                details: "Internal routes are disabled."
            ))
        }

        dependencies.append(.init(
            name: "maintenance_mode",
            status: req.application.maintenanceMode ? "warn" : "ok",
            latencyMs: nil,
            details: req.application.maintenanceMode
                ? "Maintenance mode is enabled."
                : "Maintenance mode is disabled."
        ))

        let payload = DependenciesResponse(
            status: hasFail ? "fail" : "ok",
            timestamp: Date(),
            maintenanceMode: req.application.maintenanceMode,
            dependencies: dependencies
        )
        let response = Response(status: hasFail ? .serviceUnavailable : .ok)
        try response.content.encode(payload)
        return response
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
}
