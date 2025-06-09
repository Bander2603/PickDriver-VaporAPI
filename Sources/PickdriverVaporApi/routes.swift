import Fluent
import Vapor
import SQLKit

func routes(_ app: Application) throws {
    try app.register(collection: AuthController())
    
    
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

