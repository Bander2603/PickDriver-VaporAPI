import NIOSSL
import NIOCore
import Fluent
import FluentPostgresDriver
import PostgresNIO
import Vapor
import JWT


// configures your application
public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 3000
    app.startedAt = Date()
    app.appVersion = Environment.get("APP_VERSION")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "dev"
    app.enableInternalRoutes = envBool("ENABLE_INTERNAL_ROUTES", default: true)
    app.maintenanceMode = envBool("MAINTENANCE_MODE", default: false)
    app.internalRoutesRequireHTTPS = envBool("INTERNAL_REQUIRE_HTTPS", default: app.environment == .production)

    if app.enableInternalRoutes {
        let internalToken = Environment.get("INTERNAL_SERVICE_TOKEN")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        if let internalToken {
            app.internalServiceToken = internalToken
        } else if app.environment == .testing {
            app.internalServiceToken = "test-internal-token"
        } else {
            throw Abort(
                .internalServerError,
                reason: "INTERNAL_SERVICE_TOKEN is required when ENABLE_INTERNAL_ROUTES=true."
            )
        }
    }

    guard let jwtSecret = Environment.get("JWT_SECRET"), !jwtSecret.isEmpty else {
        throw Abort(.internalServerError, reason: "JWT_SECRET is required.")
    }
    app.jwt.signers.use(.hs256(key: jwtSecret))
    if let expires = Environment.get("JWT_EXPIRES_IN_SECONDS"),
       let value = Double(expires),
       value > 0 {
        app.jwtExpiration = value
    } else {
        app.jwtExpiration = 604800
    }

    let googleClientIDs = envList("GOOGLE_CLIENT_IDS")
    if !googleClientIDs.isEmpty {
        app.googleClientIDs = googleClientIDs
    } else if let googleClientID = envString("GOOGLE_CLIENT_ID") {
        app.googleClientIDs = [googleClientID]
    } else {
        app.googleClientIDs = []
    }

    let appleClientIDs = envList("APPLE_CLIENT_IDS")
    if !appleClientIDs.isEmpty {
        app.appleClientIDs = appleClientIDs
    } else if let appleClientID = envString("APPLE_CLIENT_ID") {
        app.appleClientIDs = [appleClientID]
    } else {
        app.appleClientIDs = []
    }

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
    let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber
    let username = Environment.get("DATABASE_USERNAME") ?? "vapor_username"
    let password = Environment.get("DATABASE_PASSWORD") ?? "vapor_password"
    let dbName = Environment.get("DATABASE_NAME") ?? "vapor_database"

    if app.environment == .testing {
        precondition(dbName.lowercased().contains("test"),
                     "Refusing to run tests with non-test DATABASE_NAME: \(dbName)")
    }

    let tlsMode = (Environment.get("DATABASE_TLS_MODE")
        ?? (app.environment == .production ? "require" : "disable"))
        .lowercased()
    let tls = try makePostgresTLS(mode: tlsMode)
    let postgresConfig = SQLPostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: dbName,
        tls: tls
    )

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    if let drillConfig = try makeDrillPostgresConfiguration(app: app, fallbackTLSMode: tlsMode) {
        app.databases.use(.postgres(configuration: drillConfig), as: .drill, isDefault: false)
    }

    // Migrations (schema + indexes)
    app.migrations.add(CreatePgTrgmExtension())

    // Base tables
    app.migrations.add(CreateSeasons())
    app.migrations.add(CreateUsers())
    app.migrations.add(AddEmailVerificationToUsers())
    app.migrations.add(AddGoogleIDToUsers())
    app.migrations.add(AddAppleIDToUsers())
    app.migrations.add(AddInviteCodes())
    app.migrations.add(RemoveFirebaseUIDFromUsers())

    // F1 domain
    app.migrations.add(CreateF1Teams())
    app.migrations.add(CreateDrivers())
    app.migrations.add(CreateRaces())

    // League domain
    app.migrations.add(CreateLeagues())
    app.migrations.add(CreateLeagueMembers())
    app.migrations.add(CreateLeagueTeams())
    app.migrations.add(CreateTeamMembers())

    // Draft domain
    app.migrations.add(CreateRaceDrafts())
    app.migrations.add(CreatePlayerPicks())
    app.migrations.add(AddUniqueDriverPickPerDraft())
    app.migrations.add(CreatePlayerBans())
    app.migrations.add(AddAutoPickToPlayerPicks())
    app.migrations.add(CreatePlayerAutopicks())

    // Results + maintenance
    app.migrations.add(CreateRaceResults())
    app.migrations.add(CreateMaintenanceStats())
    app.migrations.add(CreateOpsAuditEvents())

    // Notifications
    app.migrations.add(CreatePushTokens())
    app.migrations.add(CreatePushNotifications())

    if app.environment != .testing {
        let initialDelaySeconds = Int64(Environment.get("DRAFT_DEADLINE_INITIAL_DELAY_SECONDS") ?? "5") ?? 5
        let intervalSeconds = Int64(Environment.get("DRAFT_DEADLINE_INTERVAL_SECONDS") ?? "60") ?? 60

        app.draftDeadlineTask = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task {
                await DraftDeadlineProcessor.processExpiredDrafts(app: app)
            }
        }
    }

    // register routes
    try routes(app)
}

private func envBool(_ key: String, default defaultValue: Bool) -> Bool {
    guard let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !raw.isEmpty else {
        return defaultValue
    }

    switch raw {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}

private func envString(_ key: String) -> String? {
    Environment.get(key)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
}

private func envList(_ key: String) -> [String] {
    guard let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return []
    }

    return raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func makeDrillPostgresConfiguration(
    app: Application,
    fallbackTLSMode: String
) throws -> SQLPostgresConfiguration? {
    let host = envString("DRILL_DB_HOST")
    let dbName = envString("DRILL_DB_NAME")
    let username = envString("DRILL_DB_USER") ?? envString("DRILL_DB_USERNAME")
    let password = envString("DRILL_DB_PASSWORD")
    let portRaw = envString("DRILL_DB_PORT")
    let tlsModeRaw = envString("DRILL_DB_SSLMODE") ?? envString("DRILL_DB_TLS_MODE")

    let hasAnyDrillSetting = [host, dbName, username, password, portRaw, tlsModeRaw].contains { $0 != nil }
    guard hasAnyDrillSetting else {
        return nil
    }

    guard let host, let dbName, let username, let password else {
        throw Abort(
            .internalServerError,
            reason: "Incomplete DRILL_DB_* configuration. Required: DRILL_DB_HOST, DRILL_DB_NAME, DRILL_DB_USER (or DRILL_DB_USERNAME), DRILL_DB_PASSWORD."
        )
    }

    if app.environment == .testing {
        precondition(
            dbName.lowercased().contains("test"),
            "Refusing to run tests with non-test DRILL_DB_NAME: \(dbName)"
        )
    }

    let port: Int
    if let portRaw {
        guard let parsedPort = Int(portRaw) else {
            throw Abort(.internalServerError, reason: "Invalid DRILL_DB_PORT: \(portRaw).")
        }
        port = parsedPort
    } else {
        port = SQLPostgresConfiguration.ianaPortNumber
    }

    let tlsMode = (tlsModeRaw ?? fallbackTLSMode).lowercased()
    let tls = try makePostgresTLS(mode: tlsMode)
    return SQLPostgresConfiguration(
        hostname: host,
        port: port,
        username: username,
        password: password,
        database: dbName,
        tls: tls
    )
}

private func makePostgresTLS(mode: String) throws -> PostgresConnection.Configuration.TLS {
    switch mode {
    case "disable":
        return .disable
    case "prefer":
        return try .prefer(makePostgresTLSContext())
    case "require":
        return try .require(makePostgresTLSContext())
    default:
        throw Abort(.internalServerError, reason: "Invalid DATABASE_TLS_MODE: \(mode). Use disable, prefer, or require.")
    }
}

private func makePostgresTLSContext() throws -> NIOSSLContext {
    var tls = TLSConfiguration.makeClientConfiguration()
    if let caFile = Environment.get("DATABASE_TLS_CA_FILE"), !caFile.isEmpty {
        tls.trustRoots = .file(caFile)
    }
    return try NIOSSLContext(configuration: tls)
}

extension DatabaseID {
    static var drill: DatabaseID {
        .init(string: "drill")
    }
}


extension Application {
    private struct StartedAtKey: StorageKey {
        typealias Value = Date
    }

    var startedAt: Date {
        get { self.storage[StartedAtKey.self] ?? Date() }
        set { self.storage[StartedAtKey.self] = newValue }
    }

    private struct AppVersionKey: StorageKey {
        typealias Value = String
    }

    var appVersion: String {
        get { self.storage[AppVersionKey.self] ?? "dev" }
        set { self.storage[AppVersionKey.self] = newValue }
    }

    private struct EnableInternalRoutesKey: StorageKey {
        typealias Value = Bool
    }

    var enableInternalRoutes: Bool {
        get { self.storage[EnableInternalRoutesKey.self] ?? true }
        set { self.storage[EnableInternalRoutesKey.self] = newValue }
    }

    private struct InternalServiceTokenKey: StorageKey {
        typealias Value = String
    }

    var internalServiceToken: String? {
        get { self.storage[InternalServiceTokenKey.self] }
        set { self.storage[InternalServiceTokenKey.self] = newValue }
    }

    private struct MaintenanceModeKey: StorageKey {
        typealias Value = Bool
    }

    var maintenanceMode: Bool {
        get { self.storage[MaintenanceModeKey.self] ?? false }
        set { self.storage[MaintenanceModeKey.self] = newValue }
    }

    private struct InternalRoutesRequireHTTPSKey: StorageKey {
        typealias Value = Bool
    }

    var internalRoutesRequireHTTPS: Bool {
        get { self.storage[InternalRoutesRequireHTTPSKey.self] ?? false }
        set { self.storage[InternalRoutesRequireHTTPSKey.self] = newValue }
    }

    private struct JWTExpirationKey: StorageKey {
        typealias Value = Double
    }

    var jwtExpiration: Double {
        get { self.storage[JWTExpirationKey.self] ?? 604800 } // 7 days
        set { self.storage[JWTExpirationKey.self] = newValue }
    }

    private struct GoogleClientIDsKey: StorageKey {
        typealias Value = [String]
    }

    var googleClientIDs: [String] {
        get { self.storage[GoogleClientIDsKey.self] ?? [] }
        set { self.storage[GoogleClientIDsKey.self] = newValue }
    }

    var googleClientID: String? {
        get { self.googleClientIDs.first }
        set { self.googleClientIDs = newValue.map { [$0] } ?? [] }
    }

    private struct AppleClientIDsKey: StorageKey {
        typealias Value = [String]
    }

    var appleClientIDs: [String] {
        get { self.storage[AppleClientIDsKey.self] ?? [] }
        set { self.storage[AppleClientIDsKey.self] = newValue }
    }

    var appleClientID: String? {
        get { self.appleClientIDs.first }
        set { self.appleClientIDs = newValue.map { [$0] } ?? [] }
    }

    private struct EmailVerificationExpirationKey: StorageKey {
        typealias Value = Double
    }

    var emailVerificationExpiration: Double {
        get { self.storage[EmailVerificationExpirationKey.self] ?? 1800 } // 30 minutes
        set { self.storage[EmailVerificationExpirationKey.self] = newValue }
    }

    private struct EmailVerificationResendIntervalKey: StorageKey {
        typealias Value = Double
    }

    var emailVerificationResendInterval: Double {
        get { self.storage[EmailVerificationResendIntervalKey.self] ?? 60 } // 1 minute
        set { self.storage[EmailVerificationResendIntervalKey.self] = newValue }
    }

    private struct PasswordResetExpirationKey: StorageKey {
        typealias Value = Double
    }

    var passwordResetExpiration: Double {
        get { self.storage[PasswordResetExpirationKey.self] ?? 1800 } // 30 minutes
        set { self.storage[PasswordResetExpirationKey.self] = newValue }
    }

    private struct PasswordResetResendIntervalKey: StorageKey {
        typealias Value = Double
    }

    var passwordResetResendInterval: Double {
        get { self.storage[PasswordResetResendIntervalKey.self] ?? 60 } // 1 minute
        set { self.storage[PasswordResetResendIntervalKey.self] = newValue }
    }

    private struct DraftDeadlineTaskKey: StorageKey {
        typealias Value = RepeatedTask
    }

    var draftDeadlineTask: RepeatedTask? {
        get { self.storage[DraftDeadlineTaskKey.self] }
        set { self.storage[DraftDeadlineTaskKey.self] = newValue }
    }
}

private extension String {
    var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
