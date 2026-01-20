import Fluent
import Vapor
import SQLKit

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())
    
    // 🔐 API grouping
    let api = app.grouped("api")

    // 🔐 Public controllers under /api/*
    try api.register(collection: RaceController())
    try api.register(collection: DriverController())
    try api.register(collection: StandingsController())
    try api.register(collection: NotificationController())

    // ✅ TeamController is already protected inside its own definition
    try api.register(collection: TeamController())
    try api.register(collection: DraftController())

    // ✅ LeagueController and PlayerController require explicit protection
    let protected = api.grouped(UserAuthenticator())
    try protected.grouped("leagues").register(collection: LeagueController())
    try protected.grouped("players").register(collection: PlayerController())

    // 🧪 Simple test endpoints (non-API path)
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
