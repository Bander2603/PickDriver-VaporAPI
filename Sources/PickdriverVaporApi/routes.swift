import Fluent
import Vapor
import SQLKit

func routes(_ app: Application) throws {
    // 🔐 Public controllers
    try app.register(collection: AuthController())
    try app.register(collection: RaceController())
    try app.register(collection: DriverController())
    try app.register(collection: StandingsController())

    // 🔐 API grouping
    let api = app.grouped("api")

    // ✅ TeamController is already protected inside its own definition
    try api.register(collection: TeamController())
    try api.register(collection: DraftController())

    // ✅ LeagueController requires explicit protection
    let protected = api.grouped(UserAuthenticator())
    try protected.grouped("leagues").register(collection: LeagueController())
    
    try protected.grouped("players").register(collection: PlayerController())

    // 🧪 Simple test endpoints
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


