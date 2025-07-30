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

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
    let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber
    let username = Environment.get("DATABASE_USERNAME") ?? "vapor_username"
    let password = Environment.get("DATABASE_PASSWORD") ?? "vapor_password"
    let dbName = Environment.get("DATABASE_NAME") ?? "vapor_database"

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
}
