//
//  RaceController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 14.06.25.
//

import Vapor
import Fluent

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
        let status: String
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
            self.status = race.effectiveStatus.rawValue
            self.completed = race.effectiveStatus == .completed
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
            .filter(\.$completed == false)
            .filter(\.$status != Race.Status.cancelled.rawValue)
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
            .filter(\.$status != Race.Status.cancelled.rawValue)
            .sort(\.$round)
            .first() else {
            throw Abort(.notFound, reason: "No current race found.")
        }
        return RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
    }

    func getByIDHandler(_ req: Request) async throws -> RacePublic {
        guard let race = try await Race.find(req.parameters.get("raceID"), on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }
        return RacePublic(race: race, media: MediaAssetService.raceMedia(for: race, req: req))
    }
}
