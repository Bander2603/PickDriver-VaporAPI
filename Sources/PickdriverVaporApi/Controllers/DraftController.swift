//
//  DraftController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 24.06.25.
//

import Vapor
import Fluent
import SQLKit

struct DraftController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(UserAuthenticator())
        protected.post("leagues", ":leagueID", "draft", ":raceID", "pick", use: makePick)
        protected.post("leagues", ":leagueID", "draft", ":raceID", "ban", use: banPick)
    }

    struct PickRequest: Content {
        let driverID: Int
    }

    struct BanRequest: Content {
        let targetUserID: Int
        let driverID: Int
    }

    struct DraftResponse: Content {
        let status: String
        let currentPickIndex: Int
        let nextUserID: Int?
        let bannedDriverIDs: [Int]
        let pickedDriverIDs: [Int]
        let yourTurn: Bool
        let yourDeadline: Date
    }

    func makePick(_ req: Request) async throws -> DraftResponse {
        let sql = req.db as! any SQLDatabase
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league or race ID")
        }

        guard let draft = try await RaceDraft.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first() else {
            throw Abort(.notFound, reason: "Draft not found")
        }

        let draftID = try draft.requireID()
        let deadlines = try await LeagueController().getDraftDeadlines(req)
        let now = Date()

        let pickOrder = draft.pickOrder
        let isTeamLeague = try await League.find(leagueID, on: req.db)?.teamsEnabled ?? false
        let currentTurnUserID = pickOrder[draft.currentPickIndex]

        let isMyTurn = currentTurnUserID == userID
        var isTeammate = false

        if isTeamLeague && now > deadlines.secondHalfDeadline.addingTimeInterval(-3600) {
            isTeammate = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == currentTurnUserID)
                .filter(\TeamMember.$user.$id == userID)
                .count() > 0
        }

        guard isMyTurn || isTeammate else {
            throw Abort(.forbidden, reason: "It's not your turn to pick")
        }

        let data = try req.content.decode(PickRequest.self)

        let existingPick = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: currentTurnUserID)
              AND is_banned = false
            LIMIT 1
        """).first()

        guard existingPick == nil else {
            throw Abort(.conflict, reason: "Pick already submitted")
        }

        let bannedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: currentTurnUserID)
              AND is_banned = true
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        guard !bannedDrivers.contains(data.driverID) else {
            throw Abort(.badRequest, reason: "Driver is banned for you")
        }

        let pickedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = false
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        guard !pickedDrivers.contains(data.driverID) else {
            throw Abort(.conflict, reason: "Driver already picked")
        }

        try await sql.raw("""
            INSERT INTO player_picks (draft_id, user_id, driver_id, is_banned, created_at)
            VALUES (\(bind: draftID), \(bind: currentTurnUserID), \(bind: data.driverID), false, NOW())
        """).run()

        draft.currentPickIndex += 1
        try await draft.save(on: req.db)

        let nextUserID = draft.currentPickIndex < pickOrder.count ? pickOrder[draft.currentPickIndex] : nil
        let yourDeadline = pickOrder.first == userID ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline

        return DraftResponse(
            status: "ok",
            currentPickIndex: draft.currentPickIndex,
            nextUserID: nextUserID,
            bannedDriverIDs: bannedDrivers,
            pickedDriverIDs: pickedDrivers + [data.driverID],
            yourTurn: false,
            yourDeadline: yourDeadline
        )
    }

    func banPick(_ req: Request) async throws -> DraftResponse {
        let sql = req.db as! any SQLDatabase
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league or race ID")
        }

        guard let draft = try await RaceDraft.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first() else {
            throw Abort(.notFound, reason: "Draft not found")
        }

        let draftID = try draft.requireID()
        let data = try req.content.decode(BanRequest.self)

        guard let _ = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: data.targetUserID)
              AND driver_id = \(bind: data.driverID)
              AND is_banned = false
            LIMIT 1
        """).first() else {
            throw Abort(.notFound, reason: "Pick to ban not found")
        }

        let pickOrder = draft.pickOrder
        guard let userIndex = pickOrder.firstIndex(of: userID),
              let targetIndex = pickOrder.firstIndex(of: data.targetUserID) else {
            throw Abort(.badRequest, reason: "User not found in pick order")
        }

        let league = try await League.find(leagueID, on: req.db)
        let isTeamLeague = league?.teamsEnabled ?? false

        var validBan = targetIndex == userIndex - 1

        if !validBan && isTeamLeague {
            let sameTeam = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == data.targetUserID)
                .filter(\TeamMember.$user.$id == userID)
                .count() > 0

            validBan = sameTeam
        }

        guard validBan else {
            throw Abort(.forbidden, reason: "You can only ban the previous pick")
        }

        let banLimit = isTeamLeague ? 3 : 2

        let bansUsed = try await sql.raw("""
            SELECT COUNT(*) as count FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = true
              AND banned_by = \(bind: userID)
        """).first(decoding: [String: Int].self)?["count"] ?? 0

        guard bansUsed < banLimit else {
            throw Abort(.badRequest, reason: "No bans remaining")
        }

        try await sql.raw("""
            UPDATE player_picks
            SET is_banned = true, banned_by = \(bind: userID), banned_at = NOW()
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: data.targetUserID)
              AND driver_id = \(bind: data.driverID)
        """).run()

        let deadlines = try await LeagueController().getDraftDeadlines(req)
        let now = Date()
        let firstUser = pickOrder.first
        let lastUser = pickOrder.last

        if userID == firstUser && data.targetUserID == lastUser && now < deadlines.firstHalfDeadline {
            print("⚠️ Special deadline handling triggered: first user will use second half deadline")
        }

        let bannedDriverIDs = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: data.targetUserID)
              AND is_banned = true
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        let pickedDriverIDs = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = false
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        return DraftResponse(
            status: "ok",
            currentPickIndex: draft.currentPickIndex,
            nextUserID: draft.pickOrder[safe: draft.currentPickIndex],
            bannedDriverIDs: bannedDriverIDs,
            pickedDriverIDs: pickedDriverIDs,
            yourTurn: false,
            yourDeadline: deadlines.secondHalfDeadline
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
