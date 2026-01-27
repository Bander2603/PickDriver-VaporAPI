import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor
import JWT


// configures your application
public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 3000
    app.jwt.signers.use(.hs256(key: Environment.get("JWT_SECRET")!))
    app.jwtExpiration = Double(Environment.get("JWT_EXPIRES_IN_SECONDS") ?? "604800")!
    app.emailVerificationExpiration = Double(Environment.get("EMAIL_VERIFICATION_EXPIRES_IN_SECONDS") ?? "86400")!
    app.emailVerificationResendInterval = Double(Environment.get("EMAIL_VERIFICATION_RESEND_INTERVAL_SECONDS") ?? "60")!
    app.emailVerificationLinkBaseURL = Environment.get("EMAIL_VERIFICATION_LINK_BASE")
        ?? "http://localhost:3000/api/auth/verify-email-link"
    app.emailVerificationSuccessRedirectURL = Environment.get("EMAIL_VERIFICATION_REDIRECT_URL")

    let emailProvider = (Environment.get("EMAIL_PROVIDER") ?? "log").lowercased()
    switch emailProvider {
    case "sendgrid":
        guard let apiKey = Environment.get("SENDGRID_API_KEY"),
              let fromEmail = Environment.get("SENDGRID_FROM_EMAIL") else {
            fatalError("Missing SENDGRID_API_KEY or SENDGRID_FROM_EMAIL for email provider sendgrid.")
        }
        let fromName = Environment.get("SENDGRID_FROM_NAME")
        app.emailService = SendGridEmailService(apiKey: apiKey, fromEmail: fromEmail, fromName: fromName)
    default:
        app.emailService = LogEmailService()
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

    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none

    let postgresConfig = SQLPostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: dbName,
        tls: .prefer(try .init(configuration: tls))
    )

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    
    // Migrations (schema + indexes)
    app.migrations.add(CreatePgTrgmExtension())

    // Base tables
    app.migrations.add(CreateSeasons())
    app.migrations.add(CreateUsers())
    app.migrations.add(AddEmailVerificationToUsers())
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

    // Notifications
    app.migrations.add(CreatePushTokens())
    app.migrations.add(CreatePushNotifications())

    // register routes
    try routes(app)
}


extension Application {
    private struct JWTExpirationKey: StorageKey {
        typealias Value = Double
    }

    var jwtExpiration: Double {
        get { self.storage[JWTExpirationKey.self] ?? 604800 } // 7 days
        set { self.storage[JWTExpirationKey.self] = newValue }
    }

    private struct EmailVerificationExpirationKey: StorageKey {
        typealias Value = Double
    }

    var emailVerificationExpiration: Double {
        get { self.storage[EmailVerificationExpirationKey.self] ?? 86400 } // 24 hours
        set { self.storage[EmailVerificationExpirationKey.self] = newValue }
    }

    private struct EmailVerificationResendIntervalKey: StorageKey {
        typealias Value = Double
    }

    var emailVerificationResendInterval: Double {
        get { self.storage[EmailVerificationResendIntervalKey.self] ?? 60 } // 1 minute
        set { self.storage[EmailVerificationResendIntervalKey.self] = newValue }
    }
}
