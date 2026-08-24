import Fluent
import SQLKit
import XCTVapor
@testable import PickdriverVaporApi

final class CriticalSecurityTests: XCTestCase {
    private let internalToken = "test-internal-token"

    func testUserJWTCannotCancelRaceThroughPublicOrInternalRoute() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Protected Race",
                completed: false
            )
            let raceID = try race.requireID()
            let user = try await TestAuth.register(app: app)

            try await app.test(.POST, "/api/races/\(raceID)/cancel", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            })

            try await app.test(.POST, "/api/internal/races/\(raceID)/cancel", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.POST, "/api/internal/races/\(raceID)/cancel", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: "wrong-token")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            let unchanged = try await Race.find(raceID, on: app.db)
            XCTAssertEqual(unchanged?.effectiveStatus, .scheduled)
            XCTAssertFalse(unchanged?.completed ?? true)
        }
    }

    func testInternalTokenCanCancelRace() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Internal Race",
                completed: false
            )
            let raceID = try race.requireID()

            try await app.test(.POST, "/api/internal/races/\(raceID)/cancel", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: "X-Internal-Token", value: internalToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let response = try res.content.decode(InternalRaceAdministrationController.RaceStatusResponse.self)
                XCTAssertEqual(response.raceID, raceID)
                XCTAssertEqual(response.status, Race.Status.cancelled.rawValue)
            })

            let cancelled = try await Race.find(raceID, on: app.db)
            XCTAssertEqual(cancelled?.effectiveStatus, .cancelled)
        }
    }

    func testUserJWTCannotPublishResultsAndDoesNotMutateRace() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Unpublished Race",
                completed: false
            )
            let raceID = try race.requireID()
            let user = try await TestAuth.register(app: app)

            try await app.test(.POST, "/api/races/\(raceID)/results/publish", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            })

            try await app.test(.POST, "/api/internal/races/\(raceID)/results/publish", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: user.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            let unchanged = try await Race.find(raceID, on: app.db)
            XCTAssertEqual(unchanged?.effectiveStatus, .scheduled)

            struct CountRow: Decodable { let count: Int }
            let sql = try XCTUnwrap(app.db as? (any SQLDatabase))
            let notifications = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM push_notifications
                WHERE race_id = \(bind: raceID)
            """).first(decoding: CountRow.self)
            XCTAssertEqual(notifications?.count, 0)
        }
    }

    func testAppleBodyEmailCannotClaimExistingAccountWhenVerifiedIdentityHasNoEmail() async throws {
        try await withTestApp { app in
            let victim = try await TestAuth.register(app: app)
            let request = AppleAuthRequest(
                idToken: "verified-elsewhere",
                email: victim.email,
                firstName: "Attacker",
                lastName: nil
            )
            let identity = VerifiedAppleIdentity(
                subject: "apple-attacker-subject",
                email: nil,
                emailVerified: nil
            )

            do {
                _ = try await AuthController.resolveAppleUser(request, identity: identity, on: app.db)
                XCTFail("Expected Apple identity without a signed email to be rejected")
            } catch let abort as Abort {
                XCTAssertEqual(abort.status, .badRequest)
            }

            let reloaded = try await User.query(on: app.db)
                .filter(\.$email == victim.email)
                .first()
            XCTAssertNil(reloaded?.appleID)
        }
    }

    func testLinkedAppleIdentityCanSignInWithoutEmail() async throws {
        try await withTestApp { app in
            let existing = try await TestAuth.register(app: app)
            let storedUser = try await User.query(on: app.db)
                .filter(\.$email == existing.email)
                .first()
            let stored = try XCTUnwrap(storedUser)
            stored.appleID = "apple-linked-subject"
            try await stored.save(on: app.db)

            let request = AppleAuthRequest(
                idToken: "verified-elsewhere",
                email: "ignored@example.com",
                firstName: nil,
                lastName: nil
            )
            let identity = VerifiedAppleIdentity(
                subject: "apple-linked-subject",
                email: nil,
                emailVerified: nil
            )

            let resolved = try await AuthController.resolveAppleUser(request, identity: identity, on: app.db)
            XCTAssertEqual(try resolved.requireID(), try stored.requireID())
        }
    }

    func testAppleSignedEmailWinsOverConflictingBodyEmail() async throws {
        try await withTestApp { app in
            let victim = try await TestAuth.register(app: app)
            let request = AppleAuthRequest(
                idToken: "verified-elsewhere",
                email: "attacker-controlled@example.com",
                firstName: "Ignored",
                lastName: nil
            )
            let identity = VerifiedAppleIdentity(
                subject: "apple-victim-subject",
                email: victim.email.uppercased(),
                emailVerified: true
            )

            let resolved = try await AuthController.resolveAppleUser(request, identity: identity, on: app.db)
            XCTAssertEqual(resolved.email, victim.email)
            XCTAssertEqual(resolved.appleID, identity.subject)

            let attackerBodyAccount = try await User.query(on: app.db)
                .filter(\.$email == "attacker-controlled@example.com")
                .first()
            XCTAssertNil(attackerBodyAccount)
        }
    }
}
