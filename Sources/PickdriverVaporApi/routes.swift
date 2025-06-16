import Fluent
import Vapor
import SQLKit

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())
    try app.register(collection: RaceController())
    try app.register(collection: DriverController())
    try app.register(collection: StandingsController())
    try app.register(collection: LeagueController())

    
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

