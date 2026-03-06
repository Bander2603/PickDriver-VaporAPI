//
//  RaceController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 14.06.25.
//

import Vapor
import Fluent
import SQLKit

struct RaceController: RouteCollection {
    struct RaceMedia: Content {
        let countryFlagURL: String
        let circuitURL: String
        let circuitSimpleURL: String
    }

    struct RacePublic: Content {
        let id: Int?
        let seasonID: Int
        let round: Int
        let name: String
        let circuitName: String
        let circuitData: Race.CircuitData?
        let country: String
        let countryCode: String
        let sprint: Bool
        let completed: Bool
        let fp1Time: Date?
        let fp2Time: Date?
        let fp3Time: Date?
        let qualifyingTime: Date?
        let sprintTime: Date?
        let raceTime: Date?
        let sprintQualifyingTime: Date?
        let media: RaceMedia

        init(race: Race, media: RaceMedia) {
            self.id = race.id
            self.seasonID = race.seasonID
            self.round = race.round
            self.name = race.name
            self.circuitName = race.circuitName
            self.circuitData = race.circuitData
            self.country = race.country
            self.countryCode = race.countryCode
            self.sprint = race.sprint
            self.completed = race.completed
            self.fp1Time = race.fp1Time
            self.fp2Time = race.fp2Time
            self.fp3Time = race.fp3Time
            self.qualifyingTime = race.qualifyingTime
            self.sprintTime = race.sprintTime
            self.raceTime = race.raceTime
            self.sprintQualifyingTime = race.sprintQualifyingTime
            self.media = media
        }
    }

    func boot(routes: any RoutesBuilder) throws {
        let races = routes.grouped("races")
        races.get(use: getAllHandler)
        races.get("upcoming", use: getUpcomingHandler)
        races.get("current", use: getCurrentHandler)
        races.get(":raceID", use: getByIDHandler)

        let protected = routes.grouped(UserAuthenticator())
        protected.post("races", ":raceID", "results", "publish", use: publishResults)
    }

    struct PublishResultsResponse: Content {
        let createdNotifications: Int
    }

    func getAllHandler(_ req: Request) async throws -> [RacePublic] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        let races = try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .sort(\.$round)
            .all()

        return races.map { race in
            RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
        }
    }

    func getUpcomingHandler(_ req: Request) async throws -> [RacePublic] {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        let races = try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .filter(\.$raceTime > Date())
            .sort(\.$raceTime)
            .all()

        return races.map { race in
            RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
        }
    }

    func getCurrentHandler(_ req: Request) async throws -> RacePublic {
        let activeSeasonID = try await Season.requireActiveID(on: req.db)

        guard let race = try await Race.query(on: req.db)
            .filter(\.$seasonID == activeSeasonID)
            .filter(\.$completed == false)
            .filter(\.$raceTime > Date())
            .sort(\.$raceTime)
            .first() else {
            throw Abort(.notFound, reason: "No upcoming race found.")
        }
        return RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
    }

    func getByIDHandler(_ req: Request) async throws -> RacePublic {
        guard let race = try await Race.find(req.parameters.get("raceID"), on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }
        return RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
    }

    func publishResults(_ req: Request) async throws -> PublishResultsResponse {
        _ = try req.auth.require(User.self)

        guard let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid race ID.")
        }

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required.")
        }

        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
            SELECT COUNT(*)::int AS count
            FROM race_results
            WHERE race_id = \(bind: raceID)
        """).first(decoding: CountRow.self)

        guard (row?.count ?? 0) > 0 else {
            throw Abort(.badRequest, reason: "No results found for this race.")
        }

        if !race.completed {
            race.completed = true
            try await race.save(on: req.db)
        }

        let created = try await NotificationService.notifyRaceResults(
            on: req.db,
            app: req.application,
            raceID: raceID
        )
        return PublishResultsResponse(createdNotifications: created)
    }
}
