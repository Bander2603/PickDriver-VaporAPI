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

    private func advanceExpiredTurns(
        draft: RaceDraft,
        league: League,
        deadlines: DraftDeadline,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        let pickOrder = draft.pickOrder
        guard !pickOrder.isEmpty else { return }

        var index = draft.currentPickIndex
        var advanced = false
        let firstHalfCount = (pickOrder.count + 1) / 2
        let draftID = try draft.requireID()
        let leagueID = try league.requireID()

        while index < pickOrder.count {
            let deadline = index < firstHalfCount ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline
            if now <= deadline { break }
            let currentTurnUserID = pickOrder[index]
            let isMirrorPick = draft.mirrorPicks && pickOrder.prefix(index).contains(currentTurnUserID)
            _ = try await attemptAutopick(
                draftID: draftID,
                leagueID: leagueID,
                userID: currentTurnUserID,
                isMirrorPick: isMirrorPick,
                sql: sql
            )
            index += 1
            advanced = true
        }

        if advanced {
            let row = try await sql.raw("""
                UPDATE race_drafts
                SET current_pick_index = GREATEST(current_pick_index, \(bind: index))
                WHERE id = \(bind: draftID)
                RETURNING current_pick_index
            """).first(decoding: [String: Int].self)
            if let current = row?["current_pick_index"] {
                draft.currentPickIndex = current
            } else {
                draft.currentPickIndex = index
            }
        }
    }

    private func attemptAutopick(
        draftID: Int,
        leagueID: Int,
        userID: Int,
        isMirrorPick: Bool,
        sql: any SQLDatabase
    ) async throws -> Int? {
        let existingPick = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
              AND is_banned = false
              AND is_mirror_pick = \(bind: isMirrorPick)
            LIMIT 1
        """).first()

        guard existingPick == nil else { return nil }

        let autopickRow = try await sql.raw("""
            SELECT driver_order FROM player_autopicks
            WHERE league_id = \(bind: leagueID)
              AND user_id = \(bind: userID)
            LIMIT 1
        """).first(decoding: [String: [Int]].self)

        guard let driverOrder = autopickRow?["driver_order"], !driverOrder.isEmpty else {
            return nil
        }

        let bannedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: userID)
              AND is_banned = true
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        let pickedDrivers = try await sql.raw("""
            SELECT driver_id FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = false
        """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

        let availableDrivers = driverOrder.filter { !bannedDrivers.contains($0) && !pickedDrivers.contains($0) }

        for driverID in availableDrivers {
            let inserted = try await sql.raw("""
                INSERT INTO player_picks (draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick, picked_at)
                VALUES (\(bind: draftID), \(bind: userID), \(bind: driverID), false, \(bind: isMirrorPick), true, NOW())
                ON CONFLICT DO NOTHING
                RETURNING id
            """).first(decoding: [String: Int].self)

            if inserted != nil {
                return driverID
            }

            let pickExists = try await sql.raw("""
                SELECT 1 FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND user_id = \(bind: userID)
                  AND is_banned = false
                  AND is_mirror_pick = \(bind: isMirrorPick)
                LIMIT 1
            """).first()

            if pickExists != nil {
                return nil
            }
        }

        return nil
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

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found")
        }

        let now = Date()
        if race.completed || (race.raceTime != nil && race.raceTime! < now) {
            throw Abort(.badRequest, reason: "Race already started")
        }

        let draftID = try draft.requireID()
        let deadlines = try await LeagueController().getDraftDeadlines(req)
        try await advanceExpiredTurns(draft: draft, league: league, deadlines: deadlines, now: now, sql: sql)

        let pickOrder = draft.pickOrder
        guard draft.currentPickIndex >= 0 && draft.currentPickIndex < pickOrder.count else {
            throw Abort(.badRequest, reason: "Draft is already completed")
        }

        let currentTurnUserID = pickOrder[draft.currentPickIndex]
        let isTeamLeague = league.teamsEnabled
        
        let isMyTurn = currentTurnUserID == userID
        var isTeammate = false

        if isTeamLeague && now > deadlines.secondHalfDeadline.addingTimeInterval(-3600) {
            // Resolve team of current turn user and requesting user, within this league
            let currentTurnTeamID = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == currentTurnUserID)
                .first()?
                .$team.id

            let myTeamID = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == userID)
                .first()?
                .$team.id

            if let a = currentTurnTeamID, let b = myTeamID {
                isTeammate = (a == b)
            }
        }
        
        guard isMyTurn || isTeammate else {
            throw Abort(.forbidden, reason: "It's not your turn to pick")
        }
        
        let data = try req.content.decode(PickRequest.self)

        guard let driver = try await Driver.find(data.driverID, on: req.db) else {
            throw Abort(.notFound, reason: "Driver not found")
        }

        guard driver.seasonID == race.seasonID else {
            throw Abort(.badRequest, reason: "Driver is not in this season")
        }
        
        let isMirrorPick = draft.mirrorPicks && pickOrder.prefix(draft.currentPickIndex).contains(currentTurnUserID)

        let existingPick = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: currentTurnUserID)
              AND is_banned = false
              AND is_mirror_pick = \(bind: isMirrorPick)
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
        
        do {
            try await sql.raw("""
                INSERT INTO player_picks (draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick, picked_at)
                VALUES (\(bind: draftID), \(bind: currentTurnUserID), \(bind: data.driverID), false, \(bind: isMirrorPick), false, NOW())
            """).run()
        } catch {
            let driverTaken = try await sql.raw("""
                SELECT 1 FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND driver_id = \(bind: data.driverID)
                  AND is_banned = false
                LIMIT 1
            """).first()

            if driverTaken != nil {
                throw Abort(.conflict, reason: "Driver already picked")
            }

            let pickExists = try await sql.raw("""
                SELECT 1 FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND user_id = \(bind: currentTurnUserID)
                  AND is_banned = false
                  AND is_mirror_pick = \(bind: isMirrorPick)
                LIMIT 1
            """).first()

            if pickExists != nil {
                throw Abort(.conflict, reason: "Pick already submitted")
            }

            throw error
        }
        
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

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found")
        }

        let now = Date()
        if race.completed || (race.raceTime != nil && race.raceTime! < now) {
            throw Abort(.badRequest, reason: "Race already started")
        }
        
        let draftID = try draft.requireID()
        let data = try req.content.decode(BanRequest.self)
        
        // Prevent banning the last player in the draft
        let isLastInOrder = draft.pickOrder.last == data.targetUserID
        let isFirstInOrder = draft.pickOrder.first == data.targetUserID

        if isLastInOrder && !isFirstInOrder {
            throw Abort(.forbidden, reason: "You cannot ban the last player in the draft.")
        }
        
        // Prevent banning same user more than once
        let duplicateBan = try await sql.raw("""
            SELECT 1 FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: data.targetUserID)
              AND is_banned = true
              AND banned_by = \(bind: userID)
            LIMIT 1
        """).first()
        
        if duplicateBan != nil {
            throw Abort(.forbidden, reason: "You already banned this player in this draft.")
        }
        
        // Check if the ban target pick exists
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
        
        // Get pick positions
        let pickOrder = draft.pickOrder
        let deadlines = try await LeagueController().getDraftDeadlines(req)
        try await advanceExpiredTurns(draft: draft, league: league, deadlines: deadlines, now: now, sql: sql)

        guard draft.currentPickIndex >= 0 && draft.currentPickIndex < pickOrder.count else {
            throw Abort(.badRequest, reason: "Draft is already completed")
        }
        guard draft.currentPickIndex > 0 else {
            throw Abort(.badRequest, reason: "No previous pick to ban")
        }

        let currentTurnUserID = pickOrder[draft.currentPickIndex]
        let targetIndex = draft.currentPickIndex - 1
        let expectedTargetUserID = pickOrder[targetIndex]
        
        // Ban permissions
        guard league.bansEnabled else {
            throw Abort(.badRequest, reason: "Bans are disabled in this league")
        }

        let isTeamLeague = league.teamsEnabled

        let isMyTurn = currentTurnUserID == userID
        var isTeammate = false

        if !isMyTurn && isTeamLeague {
            let currentTurnTeamID = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == currentTurnUserID)
                .first()?
                .$team.id

            let myTeamID = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .filter(TeamMember.self, \TeamMember.$user.$id == userID)
                .first()?
                .$team.id

            if let a = currentTurnTeamID, let b = myTeamID {
                isTeammate = (a == b)
            }
        }

        guard isMyTurn || isTeammate else {
            throw Abort(.forbidden, reason: "It's not your turn to ban")
        }

        guard data.targetUserID == expectedTargetUserID else {
            throw Abort(.forbidden, reason: "You can only ban the previous pick")
        }
        
        let (banKeyField, banKeyValue, isTeamScope): (String, Int, Bool) = try await {
            if isTeamLeague {
                let teamID = try await TeamMember.query(on: req.db)
                    .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                    .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                    .filter(\TeamMember.$user.$id == userID)
                    .first()?
                    .$team.id

                guard let teamID else {
                    throw Abort(.badRequest, reason: "Could not resolve team ID")
                }

                return ("team_id", teamID, true)
            } else {
                return ("user_id", userID, false)
            }
        }()

        let banRow = try await sql.raw("""
            SELECT bans_remaining FROM player_bans
            WHERE draft_id = \(bind: draftID)
              AND \(unsafeRaw: banKeyField) = \(bind: banKeyValue)
              AND is_team_scope = \(bind: isTeamScope)
            LIMIT 1
        """).first(decoding: [String: Int].self)

        let bansRemaining = banRow?["bans_remaining"] ?? (isTeamScope ? 3 : 2)

        guard bansRemaining > 0 else {
            throw Abort(.badRequest, reason: "No bans remaining")
        }

        if banRow == nil {
            try await sql.raw("""
                INSERT INTO player_bans (draft_id, \(unsafeRaw: banKeyField), bans_remaining, is_team_scope)
                VALUES (\(bind: draftID), \(bind: banKeyValue), \(bind: bansRemaining - 1), \(bind: isTeamScope))
            """).run()
        } else {
            try await sql.raw("""
                UPDATE player_bans
                SET bans_remaining = \(bind: bansRemaining - 1)
                WHERE draft_id = \(bind: draftID)
                  AND \(unsafeRaw: banKeyField) = \(bind: banKeyValue)
                  AND is_team_scope = \(bind: isTeamScope)
            """).run()
        }
        
        // Mark the target pick as banned
        try await sql.raw("""
            UPDATE player_picks
            SET is_banned = true, banned_by = \(bind: userID), banned_at = NOW()
            WHERE draft_id = \(bind: draftID)
              AND user_id = \(bind: data.targetUserID)
              AND driver_id = \(bind: data.driverID)
        """).run()
        
        // Special deadline handling
        if userID == pickOrder.first && data.targetUserID == pickOrder.last && now < deadlines.firstHalfDeadline {
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
        
        draft.currentPickIndex = targetIndex
        try await draft.save(on: req.db)
        
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
