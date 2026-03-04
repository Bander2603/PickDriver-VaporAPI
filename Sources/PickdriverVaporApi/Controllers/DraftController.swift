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
    private static let teammatePickWindowOffset: TimeInterval = 3600

    private struct LockedDraftRow: Decodable {
        let id: Int
        let pick_order: [Int]
        let current_pick_index: Int
        let mirror_picks: Bool
    }

    private struct ExistingPickRow: Decodable {
        let id: Int
        let driver_id: Int
    }

    private struct PendingTurnNotification {
        let recipientID: Int
        let draftID: Int
        let pickIndex: Int
    }

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
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let data = try req.content.decode(PickRequest.self)

        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league or race ID")
        }

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found")
        }

        let now = Date()
        if race.completed || (race.raceTime != nil && race.raceTime! < now) {
            throw Abort(.badRequest, reason: "Race already started")
        }

        guard let driver = try await Driver.find(data.driverID, on: req.db) else {
            throw Abort(.notFound, reason: "Driver not found")
        }

        guard driver.seasonID == race.seasonID else {
            throw Abort(.badRequest, reason: "Driver is not in this season")
        }
        let deadlines = try makeDraftDeadlines(leagueID: leagueID, raceID: raceID, race: race)

        let outcome = try await req.db.transaction { tx -> (DraftResponse, PendingTurnNotification?) in
            guard let sql = tx as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for draft picks.")
            }

            let draft = try await lockDraft(leagueID: leagueID, raceID: raceID, sql: sql)
            let draftID = draft.id
            let pickOrder = draft.pick_order
            guard !pickOrder.isEmpty else {
                throw Abort(.badRequest, reason: "Draft is already completed")
            }

            var currentPickIndex = try await DraftDeadlineProcessor.advanceExpiredTurns(
                draftID: draftID,
                leagueID: leagueID,
                pickOrder: pickOrder,
                currentPickIndex: draft.current_pick_index,
                mirrorPicks: draft.mirror_picks,
                deadlines: deadlines,
                now: now,
                sql: sql
            )

            guard currentPickIndex >= 0 && currentPickIndex < pickOrder.count else {
                throw Abort(.badRequest, reason: "Draft is already completed")
            }

            let currentTurnUserID = pickOrder[currentPickIndex]
            var canPickForCurrentTurn = currentTurnUserID == userID

            if !canPickForCurrentTurn,
               league.teamsEnabled,
               now > deadlines.secondHalfDeadline.addingTimeInterval(-Self.teammatePickWindowOffset) {
                canPickForCurrentTurn = try await areTeammates(
                    leagueID: leagueID,
                    userA: userID,
                    userB: currentTurnUserID,
                    on: tx
                )
            }

            let pickUserID: Int
            let pickIndex: Int
            let isMirrorPick: Bool
            var editedExistingPick = false
            var existingEditablePick: ExistingPickRow?

            if canPickForCurrentTurn {
                pickUserID = currentTurnUserID
                pickIndex = currentPickIndex
                isMirrorPick = draft.mirror_picks && pickOrder.prefix(pickIndex).contains(pickUserID)

                let existingPick = try await sql.raw("""
                    SELECT 1 FROM player_picks
                    WHERE draft_id = \(bind: draftID)
                      AND user_id = \(bind: pickUserID)
                      AND is_banned = false
                      AND is_mirror_pick = \(bind: isMirrorPick)
                    LIMIT 1
                """).first()

                guard existingPick == nil else {
                    throw Abort(.conflict, reason: "Pick already submitted")
                }
            } else {
                guard currentPickIndex > 0 else {
                    throw Abort(.forbidden, reason: "It's not your turn to pick")
                }

                let editableIndex = currentPickIndex - 1
                let editableUserID = pickOrder[editableIndex]

                guard editableUserID == userID else {
                    throw Abort(.forbidden, reason: "It's not your turn to pick")
                }

                let editableDeadline = deadlineForPickIndex(
                    pickIndex: editableIndex,
                    totalPickCount: pickOrder.count,
                    deadlines: deadlines
                )
                guard now <= editableDeadline else {
                    throw Abort(.conflict, reason: "Your turn is no longer active")
                }

                let nextSlotMirror = draft.mirror_picks && pickOrder.prefix(currentPickIndex).contains(currentTurnUserID)
                let nextSlotHasPick = try await sql.raw("""
                    SELECT 1 FROM player_picks
                    WHERE draft_id = \(bind: draftID)
                      AND user_id = \(bind: currentTurnUserID)
                      AND is_banned = false
                      AND is_mirror_pick = \(bind: nextSlotMirror)
                    LIMIT 1
                """).first()

                guard nextSlotHasPick == nil else {
                    throw Abort(.conflict, reason: "Your turn is no longer active")
                }

                pickUserID = editableUserID
                pickIndex = editableIndex
                isMirrorPick = draft.mirror_picks && pickOrder.prefix(pickIndex).contains(pickUserID)

                existingEditablePick = try await sql.raw("""
                    SELECT id, driver_id
                    FROM player_picks
                    WHERE draft_id = \(bind: draftID)
                      AND user_id = \(bind: pickUserID)
                      AND is_banned = false
                      AND is_mirror_pick = \(bind: isMirrorPick)
                    LIMIT 1
                """).first(decoding: ExistingPickRow.self)

                guard existingEditablePick != nil else {
                    throw Abort(.conflict, reason: "Your turn is no longer active")
                }

                editedExistingPick = true
            }

            let bannedDrivers = try await sql.raw("""
                SELECT driver_id FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND user_id = \(bind: pickUserID)
                  AND is_banned = true
            """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

            guard !bannedDrivers.contains(data.driverID) else {
                throw Abort(.badRequest, reason: "Driver is banned for you")
            }

            let driverTakenByAnotherPick = try await sql.raw("""
                SELECT 1 FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND driver_id = \(bind: data.driverID)
                  AND is_banned = false
                  AND NOT (
                    user_id = \(bind: pickUserID)
                    AND is_mirror_pick = \(bind: isMirrorPick)
                  )
                LIMIT 1
            """).first()

            guard driverTakenByAnotherPick == nil else {
                throw Abort(.conflict, reason: "Driver no longer available")
            }

            if editedExistingPick {
                guard let editablePick = existingEditablePick else {
                    throw Abort(.conflict, reason: "Your turn is no longer active")
                }

                if editablePick.driver_id != data.driverID {
                    do {
                        try await sql.raw("""
                            UPDATE player_picks
                            SET driver_id = \(bind: data.driverID),
                                is_autopick = false,
                                picked_at = NOW()
                            WHERE id = \(bind: editablePick.id)
                        """).run()
                    } catch {
                        let driverTaken = try await sql.raw("""
                            SELECT 1 FROM player_picks
                            WHERE draft_id = \(bind: draftID)
                              AND driver_id = \(bind: data.driverID)
                              AND is_banned = false
                              AND id <> \(bind: editablePick.id)
                            LIMIT 1
                        """).first()

                        if driverTaken != nil {
                            throw Abort(.conflict, reason: "Driver no longer available")
                        }

                        throw error
                    }
                }
            } else {
                do {
                    try await sql.raw("""
                        INSERT INTO player_picks (draft_id, user_id, driver_id, is_banned, is_mirror_pick, is_autopick, picked_at)
                        VALUES (\(bind: draftID), \(bind: pickUserID), \(bind: data.driverID), false, \(bind: isMirrorPick), false, NOW())
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
                        throw Abort(.conflict, reason: "Driver no longer available")
                    }

                    let pickExists = try await sql.raw("""
                        SELECT 1 FROM player_picks
                        WHERE draft_id = \(bind: draftID)
                          AND user_id = \(bind: pickUserID)
                          AND is_banned = false
                          AND is_mirror_pick = \(bind: isMirrorPick)
                        LIMIT 1
                    """).first()

                    if pickExists != nil {
                        throw Abort(.conflict, reason: "Pick already submitted")
                    }

                    throw error
                }
            }

            var notification: PendingTurnNotification?
            if !editedExistingPick {
                currentPickIndex += 1
                try await sql.raw("""
                    UPDATE race_drafts
                    SET current_pick_index = \(bind: currentPickIndex),
                        updated_at = NOW()
                    WHERE id = \(bind: draftID)
                """).run()

                currentPickIndex = try await DraftDeadlineProcessor.advanceExpiredTurns(
                    draftID: draftID,
                    leagueID: leagueID,
                    pickOrder: pickOrder,
                    currentPickIndex: currentPickIndex,
                    mirrorPicks: draft.mirror_picks,
                    deadlines: deadlines,
                    now: now,
                    sql: sql
                )
            }

            let nextUserID = currentPickIndex < pickOrder.count ? pickOrder[currentPickIndex] : nil
            if !editedExistingPick, let nextUserID {
                notification = PendingTurnNotification(
                    recipientID: nextUserID,
                    draftID: draftID,
                    pickIndex: currentPickIndex
                )
            }

            let pickedDrivers = try await sql.raw("""
                SELECT driver_id FROM player_picks
                WHERE draft_id = \(bind: draftID)
                  AND is_banned = false
            """).all(decoding: [String: Int].self).map { $0["driver_id"]! }

            let yourDeadline = pickOrder.first == userID ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline
            let response = DraftResponse(
                status: "ok",
                currentPickIndex: currentPickIndex,
                nextUserID: nextUserID,
                bannedDriverIDs: bannedDrivers,
                pickedDriverIDs: pickedDrivers,
                yourTurn: false,
                yourDeadline: yourDeadline
            )

            return (response, notification)
        }

        if let notification = outcome.1 {
            try await NotificationService.notifyDraftTurn(
                on: req.db,
                app: req.application,
                recipientID: notification.recipientID,
                league: league,
                race: race,
                draftID: notification.draftID,
                pickIndex: notification.pickIndex
            )
        }

        return outcome.0
    }
    
    func banPick(_ req: Request) async throws -> DraftResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let data = try req.content.decode(BanRequest.self)
        
        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league or race ID")
        }

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let race = try await Race.find(raceID, on: req.db) else {
            throw Abort(.notFound, reason: "Race not found")
        }

        let now = Date()
        if race.completed || (race.raceTime != nil && race.raceTime! < now) {
            throw Abort(.badRequest, reason: "Race already started")
        }
        let deadlines = try makeDraftDeadlines(leagueID: leagueID, raceID: raceID, race: race)

        let outcome = try await req.db.transaction { tx -> (DraftResponse, PendingTurnNotification?) in
            guard let sql = tx as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for draft bans.")
            }

            let draft = try await lockDraft(leagueID: leagueID, raceID: raceID, sql: sql)
            let draftID = draft.id
            let pickOrder = draft.pick_order

            // Prevent banning the last player in the draft.
            let isLastInOrder = pickOrder.last == data.targetUserID
            let isFirstInOrder = pickOrder.first == data.targetUserID
            if isLastInOrder && !isFirstInOrder {
                throw Abort(.forbidden, reason: "You cannot ban the last player in the draft.")
            }

            // Check if the ban target pick exists.
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

            var currentPickIndex = try await DraftDeadlineProcessor.advanceExpiredTurns(
                draftID: draftID,
                leagueID: leagueID,
                pickOrder: pickOrder,
                currentPickIndex: draft.current_pick_index,
                mirrorPicks: draft.mirror_picks,
                deadlines: deadlines,
                now: now,
                sql: sql
            )

            guard currentPickIndex >= 0 && currentPickIndex < pickOrder.count else {
                throw Abort(.badRequest, reason: "Draft is already completed")
            }
            guard currentPickIndex > 0 else {
                throw Abort(.badRequest, reason: "No previous pick to ban")
            }

            let currentTurnUserID = pickOrder[currentPickIndex]
            let targetIndex = currentPickIndex - 1
            let expectedTargetUserID = pickOrder[targetIndex]

            guard league.bansEnabled else {
                throw Abort(.badRequest, reason: "Bans are disabled in this league")
            }

            let isTeamLeague = league.teamsEnabled
            let isMyTurn = currentTurnUserID == userID
            var isTeammate = false
            var myTeamID: Int?

            if isTeamLeague {
                myTeamID = try await resolveTeamID(userID: userID, leagueID: leagueID, on: tx)
            }

            if !isMyTurn && isTeamLeague {
                let currentTurnTeamID = try await resolveTeamID(userID: currentTurnUserID, leagueID: leagueID, on: tx)
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

            if isTeamLeague {
                guard let myTeamID else {
                    throw Abort(.badRequest, reason: "Could not resolve team ID")
                }

                let existingTeamBan = try await sql.raw("""
                    SELECT 1 FROM player_picks pp
                    JOIN team_members tm ON tm.user_id = pp.banned_by
                    WHERE pp.draft_id = \(bind: draftID)
                      AND pp.is_banned = true
                      AND tm.team_id = \(bind: myTeamID)
                    LIMIT 1
                """).first()

                guard existingTeamBan == nil else {
                    throw Abort(.badRequest, reason: "Your team already used its ban for this race.")
                }
            } else {
                let existingUserBan = try await sql.raw("""
                    SELECT 1 FROM player_picks
                    WHERE draft_id = \(bind: draftID)
                      AND is_banned = true
                      AND banned_by = \(bind: userID)
                    LIMIT 1
                """).first()

                guard existingUserBan == nil else {
                    throw Abort(.badRequest, reason: "You already used your ban for this race.")
                }

                let targetAlreadyBanned = try await sql.raw("""
                    SELECT 1 FROM player_picks
                    WHERE draft_id = \(bind: draftID)
                      AND is_banned = true
                      AND user_id = \(bind: data.targetUserID)
                    LIMIT 1
                """).first()

                guard targetAlreadyBanned == nil else {
                    throw Abort(.badRequest, reason: "That player has already been banned in this race.")
                }
            }

            let (banKeyField, banKeyValue, isTeamScope): (String, Int, Bool) = try {
                if isTeamLeague {
                    guard let teamID = myTeamID else {
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

            try await sql.raw("""
                UPDATE player_picks
                SET is_banned = true, banned_by = \(bind: userID), banned_at = NOW()
                WHERE draft_id = \(bind: draftID)
                  AND user_id = \(bind: data.targetUserID)
                  AND driver_id = \(bind: data.driverID)
            """).run()

            if userID == pickOrder.first && data.targetUserID == pickOrder.last && now < deadlines.firstHalfDeadline {
                req.logger.notice("Drafts: special deadline handling triggered")
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

            currentPickIndex = targetIndex
            try await sql.raw("""
                UPDATE race_drafts
                SET current_pick_index = \(bind: currentPickIndex),
                    updated_at = NOW()
                WHERE id = \(bind: draftID)
            """).run()

            currentPickIndex = try await DraftDeadlineProcessor.advanceExpiredTurns(
                draftID: draftID,
                leagueID: leagueID,
                pickOrder: pickOrder,
                currentPickIndex: currentPickIndex,
                mirrorPicks: draft.mirror_picks,
                deadlines: deadlines,
                now: now,
                sql: sql
            )

            let nextUserID = pickOrder[safe: currentPickIndex]
            let notification = nextUserID.map {
                PendingTurnNotification(recipientID: $0, draftID: draftID, pickIndex: currentPickIndex)
            }

            let response = DraftResponse(
                status: "ok",
                currentPickIndex: currentPickIndex,
                nextUserID: nextUserID,
                bannedDriverIDs: bannedDriverIDs,
                pickedDriverIDs: pickedDriverIDs,
                yourTurn: false,
                yourDeadline: deadlines.secondHalfDeadline
            )

            return (response, notification)
        }

        if let notification = outcome.1 {
            try await NotificationService.notifyDraftTurn(
                on: req.db,
                app: req.application,
                recipientID: notification.recipientID,
                league: league,
                race: race,
                draftID: notification.draftID,
                pickIndex: notification.pickIndex
            )
        }

        return outcome.0
    }

    private func lockDraft(
        leagueID: Int,
        raceID: Int,
        sql: any SQLDatabase
    ) async throws -> LockedDraftRow {
        guard let draft = try await sql.raw("""
            SELECT id, pick_order, current_pick_index, mirror_picks
            FROM race_drafts
            WHERE league_id = \(bind: leagueID)
              AND race_id = \(bind: raceID)
            FOR UPDATE
        """).first(decoding: LockedDraftRow.self) else {
            throw Abort(.notFound, reason: "Draft not found")
        }

        return draft
    }

    private func makeDraftDeadlines(leagueID: Int, raceID: Int, race: Race) throws -> DraftDeadline {
        guard let fp1 = race.fp1Time else {
            throw Abort(.notFound, reason: "Race not found or FP1 time missing.")
        }

        let firstHalfDeadline = Calendar.current.date(byAdding: .hour, value: -36, to: fp1)!
        return DraftDeadline(
            raceID: raceID,
            leagueID: leagueID,
            firstHalfDeadline: firstHalfDeadline,
            secondHalfDeadline: fp1
        )
    }

    private func deadlineForPickIndex(
        pickIndex: Int,
        totalPickCount: Int,
        deadlines: DraftDeadline
    ) -> Date {
        let firstHalfCount = (totalPickCount + 1) / 2
        return pickIndex < firstHalfCount ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline
    }

    private func areTeammates(
        leagueID: Int,
        userA: Int,
        userB: Int,
        on database: any Database
    ) async throws -> Bool {
        guard let teamA = try await resolveTeamID(userID: userA, leagueID: leagueID, on: database),
              let teamB = try await resolveTeamID(userID: userB, leagueID: leagueID, on: database) else {
            return false
        }

        return teamA == teamB
    }

    private func resolveTeamID(
        userID: Int,
        leagueID: Int,
        on database: any Database
    ) async throws -> Int? {
        try await TeamMember.query(on: database)
            .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
            .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
            .filter(TeamMember.self, \TeamMember.$user.$id == userID)
            .first()?
            .$team.id
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
