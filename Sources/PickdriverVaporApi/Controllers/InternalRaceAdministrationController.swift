import Fluent
import SQLKit
import Vapor

/// Global race mutations belong to the internal operational security boundary.
/// Public users may read races, but cannot change calendar or result state.
struct InternalRaceAdministrationController: RouteCollection {
    struct PublishResultsResponse: Content {
        let createdNotifications: Int
    }

    struct RaceStatusResponse: Content {
        let raceID: Int
        let status: String
        let completed: Bool
    }

    func boot(routes: any RoutesBuilder) throws {
        let races = routes.grouped("races")
        races.post(":raceID", "cancel", use: cancelRace)
        races.post(":raceID", "results", "publish", use: publishResults)
    }

    func publishResults(_ req: Request) async throws -> PublishResultsResponse {
        guard let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid race ID.")
        }

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        guard !race.isCancelled else {
            throw Abort(.badRequest, reason: "Cancelled races cannot publish results.")
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

        if race.effectiveStatus != .completed {
            race.setStatus(.completed)
            try await race.save(on: req.db)
        }

        try await PlayoffService.synchronizeActiveLeagues(on: req.db)

        let created = try await NotificationService.notifyRaceResults(
            on: req.db,
            app: req.application,
            raceID: raceID
        )
        return PublishResultsResponse(createdNotifications: created)
    }

    func cancelRace(_ req: Request) async throws -> RaceStatusResponse {
        guard let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid race ID.")
        }

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        guard race.effectiveStatus != .completed else {
            throw Abort(.badRequest, reason: "Completed races cannot be cancelled.")
        }

        if race.effectiveStatus != .cancelled {
            race.setStatus(.cancelled)
            try await race.save(on: req.db)
        }

        _ = try await RaceCancellationService.invalidateCancelledDraftIfNeeded(raceID: raceID, on: req.db)

        return RaceStatusResponse(
            raceID: raceID,
            status: race.effectiveStatus.rawValue,
            completed: race.completed
        )
    }
}
