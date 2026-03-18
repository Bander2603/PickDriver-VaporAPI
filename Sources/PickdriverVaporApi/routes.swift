import Fluent
import Vapor
import SQLKit

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())

    // Public compliance pages (Google Play privacy/account deletion).
    app.get("privacy") { req async throws -> Response in
        try await req.fileio.asyncStreamFile(
            at: req.application.directory.publicDirectory + "privacy/index.html"
        )
    }

    app.get("account-deletion") { req async throws -> Response in
        try await req.fileio.asyncStreamFile(
            at: req.application.directory.publicDirectory + "account-deletion/index.html"
        )
    }

    // API grouping
    let api = app.grouped("api").grouped(MaintenanceModeMiddleware())
    try api.register(collection: HealthController())

    // Public controllers under /api/*
    try api.register(collection: RaceController())
    try api.register(collection: DriverController())
    try api.register(collection: F1TeamController())
    try api.register(collection: StandingsController())
    try api.register(collection: NotificationController())

    // TeamController is already protected inside its own definition
    try api.register(collection: TeamController())
    try api.register(collection: DraftController())

    // LeagueController and PlayerController require explicit protection
    let protected = api.grouped(UserAuthenticator())
    try protected.grouped("leagues").register(collection: LeagueController())
    try protected.grouped("players").register(collection: PlayerController())

    if app.enableInternalRoutes {
        let internalProtected = api.grouped("internal")
            .grouped(InternalServiceAuthenticator())
            .grouped(InternalHTTPSMiddleware())
        try internalProtected.grouped("system").register(collection: InternalSystemController())
        try internalProtected.grouped("ops").register(collection: InternalOpsController())
    }

    // Simple test endpoints (non-API path)
    if app.environment != .production {
        app.get { req in
            "PickDriver Vapor API is live 🚀"
        }

        app.get("test") { req in
            "This is a test 🚀"
        }

        app.get("races") { req async throws -> [Race] in
            try await Race.query(on: req.db).all()
        }
    }
}
