//
//  NotificationTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import XCTVapor
import SQLKit
@testable import PickdriverVaporApi

final class NotificationTests: XCTestCase {

    private struct CreateLeaguePayload: Content {
        let name: String
        let maxPlayers: Int
        let teamsEnabled: Bool
        let bansEnabled: Bool
        let mirrorEnabled: Bool
    }

    private struct JoinLeaguePayload: Content {
        let code: String
    }

    private struct PickPayload: Content {
        let driverID: Int
    }

    private struct DeviceRegistrationPayload: Content {
        let token: String
        let platform: String
        let deviceID: String?
    }

    private struct PublishResultsResponse: Content {
        let createdNotifications: Int
    }

    private func sql(_ app: Application) throws -> any SQLDatabase {
        try XCTUnwrap(app.db as? (any SQLDatabase), "DB is not SQLDatabase")
    }

    private func createLeague(
        app: Application,
        token: String,
        name: String,
        maxPlayers: Int,
        teamsEnabled: Bool = false,
        bansEnabled: Bool = false,
        mirrorEnabled: Bool = false
    ) async throws -> League.Public {
        var created: League.Public?

        try await app.test(.POST, "/api/leagues/create", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(CreateLeaguePayload(
                name: name,
                maxPlayers: maxPlayers,
                teamsEnabled: teamsEnabled,
                bansEnabled: bansEnabled,
                mirrorEnabled: mirrorEnabled
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            created = try res.content.decode(League.Public.self)
        })

        return try XCTUnwrap(created)
    }

    private func joinLeague(app: Application, token: String, code: String) async throws {
        try await app.test(.POST, "/api/leagues/join", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(JoinLeaguePayload(code: code))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func startDraft(app: Application, token: String, leagueID: Int) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/start-draft", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func getPickOrder(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int
    ) async throws -> [Int] {
        var order: [Int] = []
        try await app.test(.GET, "/api/leagues/\(leagueID)/draft/\(raceID)/pick-order", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            order = try res.content.decode([Int].self)
        })
        return order
    }

    private func makePick(
        app: Application,
        token: String,
        leagueID: Int,
        raceID: Int,
        driverID: Int
    ) async throws {
        try await app.test(.POST, "/api/leagues/\(leagueID)/draft/\(raceID)/pick", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(PickPayload(driverID: driverID))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func registerDevice(
        app: Application,
        token: String,
        deviceToken: String
    ) async throws {
        try await app.test(.POST, "/api/notifications/devices", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(DeviceRegistrationPayload(token: deviceToken, platform: "ios", deviceID: "sim-1"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
        })
    }

    private func insertRaceResult(
        app: Application,
        raceID: Int,
        driverID: Int,
        points: Int,
        f1TeamID: Int
    ) async throws {
        let sql = try sql(app)
        try await sql.raw("""
            INSERT INTO race_results (race_id, driver_id, points, f1_team_id)
            VALUES (\(bind: raceID), \(bind: driverID), \(bind: points), \(bind: f1TeamID))
        """).run()
    }

    func testDraftTurnNotificationListedForNextUser() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Notify Team", color: "#111111")
            let driver = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: team.id,
                firstName: "Draft",
                lastName: "Pick",
                driverNumber: 10,
                driverCode: "DRF"
            )

            let fp1 = Date().addingTimeInterval(7 * 24 * 3600)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 1,
                name: "Notify GP",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 3600)
            )
            let raceID = try XCTUnwrap(race.id)

            let userA = try await TestAuth.register(app: app)
            let userB = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: userA.token,
                name: "Notify League",
                maxPlayers: 2,
                mirrorEnabled: false
            )

            try await joinLeague(app: app, token: userB.token, code: league.code)
            try await startDraft(app: app, token: userA.token, leagueID: try XCTUnwrap(league.id))

            let pickOrder = try await getPickOrder(
                app: app,
                token: userA.token,
                leagueID: try XCTUnwrap(league.id),
                raceID: raceID
            )

            let currentUserID = try XCTUnwrap(pickOrder.first)
            let nextUserID = try XCTUnwrap(pickOrder.dropFirst().first)
            let tokenByUserID = [
                try XCTUnwrap(userA.publicUser.id): userA.token,
                try XCTUnwrap(userB.publicUser.id): userB.token
            ]
            let currentToken = try XCTUnwrap(tokenByUserID[currentUserID])
            let nextToken = try XCTUnwrap(tokenByUserID[nextUserID])

            try await registerDevice(app: app, token: nextToken, deviceToken: "device-next")
            try await makePick(
                app: app,
                token: currentToken,
                leagueID: try XCTUnwrap(league.id),
                raceID: raceID,
                driverID: try XCTUnwrap(driver.id)
            )

            var notifications: [PushNotification.Public] = []
            try await app.test(.GET, "/api/notifications?unread_only=true", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: nextToken)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                notifications = try res.content.decode([PushNotification.Public].self)
            })

            XCTAssertTrue(notifications.contains { $0.type == PushNotificationType.draftTurn.rawValue && $0.raceID == raceID })
        }
    }

    func testRaceResultsPublishCreatesNotifications() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app, year: 2026, active: true)
            let team = try await TestSeed.createF1Team(app: app, seasonID: try season.requireID(), name: "Results Team", color: "#222222")
            let driver = try await TestSeed.createDriver(
                app: app,
                seasonID: try season.requireID(),
                f1TeamID: team.id,
                firstName: "Race",
                lastName: "Winner",
                driverNumber: 44,
                driverCode: "WIN"
            )

            let fp1 = Date().addingTimeInterval(3 * 24 * 3600)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: try season.requireID(),
                round: 2,
                name: "Results GP",
                completed: false,
                fp1Time: fp1,
                raceTime: fp1.addingTimeInterval(2 * 3600)
            )
            let raceID = try XCTUnwrap(race.id)

            let userA = try await TestAuth.register(app: app)
            let userB = try await TestAuth.register(app: app)

            let league = try await createLeague(
                app: app,
                token: userA.token,
                name: "Results League",
                maxPlayers: 2,
                mirrorEnabled: false
            )

            try await joinLeague(app: app, token: userB.token, code: league.code)
            try await startDraft(app: app, token: userA.token, leagueID: try XCTUnwrap(league.id))

            try await insertRaceResult(
                app: app,
                raceID: raceID,
                driverID: try XCTUnwrap(driver.id),
                points: 25,
                f1TeamID: team.id
            )

            var publishResponse: PublishResultsResponse?
            try await app.test(.POST, "/api/races/\(raceID)/results/publish", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: userA.token)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                publishResponse = try res.content.decode(PublishResultsResponse.self)
            })

            XCTAssertEqual(publishResponse?.createdNotifications, 2)

            struct CountRow: Decodable { let count: Int }
            let sql = try sql(app)
            let row = try await sql.raw("""
                SELECT COUNT(*)::int AS count
                FROM push_notifications
                WHERE type = \(bind: PushNotificationType.raceResults.rawValue)
                  AND race_id = \(bind: raceID)
            """).first(decoding: CountRow.self)

            XCTAssertEqual(row?.count, 2)
        }
    }
}
