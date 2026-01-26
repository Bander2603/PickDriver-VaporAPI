//
//  LeagueController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent
import SQLKit

struct LeagueController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(UserAuthenticator())

        protected.get("my", use: getMyLeagues)
        protected.post("create", use: createLeague)
        protected.post("join", use: joinLeague)
        protected.delete(":leagueID", use: deleteLeague)
        
        protected.get(":leagueID", "members", use: getLeagueMembers)
        protected.get(":leagueID", "teams", use: getLeagueTeams)
        protected.post(":leagueID", "assign-pick-order", use: assignPickOrder)
        protected.post(":leagueID", "start-draft", use: activateDraft)
        protected.get(":leagueID", "draft", ":raceID", "pick-order", use: getPickOrderForRace)
        protected.get(":leagueID", "draft", ":raceID", use: getRaceDraft)
        protected.get(":leagueID", "draft", ":raceID", "deadlines", use: getDraftDeadlines)
        protected.get(":leagueID", "autopick", use: getAutopickList)
        protected.put(":leagueID", "autopick", use: upsertAutopickList)

    }

    struct AutopickListRequest: Content {
        let driverIDs: [Int]
    }

    struct AutopickListResponse: Content {
        let driverIDs: [Int]
    }

    func getMyLeagues(_ req: Request) async throws -> [League.Public] {
        let user = try req.auth.require(User.self)

        let memberships = try await LeagueMember.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .all()

        let leagueIDs = memberships.map { $0.$league.id }

        let leagues = try await League.query(on: req.db)
            .filter(\.$id ~~ leagueIDs)
            .all()

        return leagues.map { $0.convertToPublic() }
    }

    func createLeague(_ req: Request) async throws -> League.Public {
        let user = try req.auth.require(User.self)
        let data = try req.content.decode(CreateLeagueRequest.self)

        let code = generateUniqueCode()

        guard let season = try await Season.query(on: req.db)
            .filter(\.$active == true)
            .first()
        else {
            throw Abort(.badRequest, reason: "No active season found.")
        }

        let league = League(
            name: data.name,
            code: code,
            status: "pending",
            creatorID: try user.requireID(),
            teamsEnabled: data.teamsEnabled,
            bansEnabled: data.bansEnabled,
            mirrorEnabled: data.mirrorEnabled,
            maxPlayers: data.maxPlayers,
            seasonID: try season.requireID()
        )

        try await league.save(on: req.db)

        let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
        try await member.save(on: req.db)

        return league.convertToPublic()
    }

    func deleteLeague(_ req: Request) async throws -> HTTPStatus {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        guard let league = try await League.find(leagueID, on: req.db) else {
            throw Abort(.notFound, reason: "League not found.")
        }

        try LeagueAccess.requireOwner(req, league: league)

        guard league.status.lowercased() == "pending" else {
            throw Abort(.badRequest, reason: "Only pending leagues can be deleted.")
        }

        try await league.delete(on: req.db)
        return .ok
    }

    func getLeagueMembers(_ req: Request) async throws -> [User.Public] {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$user)
            .all()

        return members.map { $0.user.convertToPublic() }
    }

    func getLeagueTeams(_ req: Request) async throws -> [LeagueTeam] {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        return try await LeagueTeam.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .with(\.$members)
            .all()
    }

    func assignPickOrder(_ req: Request) async throws -> HTTPStatus {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)
        try LeagueAccess.requireOwner(req, league: league)

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .all()

        guard !members.isEmpty else {
            throw Abort(.badRequest, reason: "No members found in this league.")
        }

        var pickOrderMembers: [LeagueMember] = []

        if league.teamsEnabled {
            let teamAssignments = try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .all()

            var teamMap: [Int: [LeagueMember]] = [:]
            for member in members {
                if let teamEntry = teamAssignments.first(where: { $0.$user.id == member.$user.id }) {
                    let teamID = teamEntry.$team.id
                    teamMap[teamID, default: []].append(member)
                }
            }

            for (teamID, list) in teamMap {
                teamMap[teamID] = list.shuffled()
            }

            let teamIDs = teamMap.keys.shuffled()
            var index = 0
            while pickOrderMembers.count < members.count {
                for teamID in teamIDs {
                    if let list = teamMap[teamID], index < list.count {
                        pickOrderMembers.append(list[index])
                    }
                }
                index += 1
            }

        } else {
            pickOrderMembers = members.shuffled()
        }

        for (index, member) in pickOrderMembers.enumerated() {
            member.pickOrder = index + 1
            try await member.save(on: req.db)
        }

        return .ok
    }

    private func generateUniqueCode(length: Int = 6) -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }
    
    func activateDraft(_ req: Request) async throws -> HTTPStatus {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID")
        }

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)
        try LeagueAccess.requireOwner(req, league: league)

        guard league.status == "pending" else {
            throw Abort(.badRequest, reason: "League must be pending to start the draft.")
        }

        let members = try await LeagueMember.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .all()

        guard members.count == league.maxPlayers else {
            throw Abort(.badRequest, reason: "Not all players have joined.")
        }

        if league.teamsEnabled {
            let allUsers = Set(members.map { $0.$user.id })
            let assignedUsers = Set(try await TeamMember.query(on: req.db)
                .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                .all()
                .map { $0.$user.id })

            guard assignedUsers == allUsers else {
                throw Abort(.badRequest, reason: "All players must be assigned to teams.")
            }
        }

        // 🔀 Use assigned pick order if present; otherwise compute a fair randomized order
        var pickOrderMembers: [LeagueMember] = []
        let assignedOrders = members.compactMap { $0.pickOrder }
        let hasAssignedOrder = assignedOrders.count == members.count
            && Set(assignedOrders).count == members.count

        if hasAssignedOrder {
            pickOrderMembers = members.sorted { ($0.pickOrder ?? 0) < ($1.pickOrder ?? 0) }
        } else {
            if league.teamsEnabled {
                let teamAssignments = try await TeamMember.query(on: req.db)
                    .join(LeagueTeam.self, on: \TeamMember.$team.$id == \LeagueTeam.$id)
                    .filter(LeagueTeam.self, \LeagueTeam.$league.$id == leagueID)
                    .all()

                var teamMap: [Int: [LeagueMember]] = [:]
                for member in members {
                    if let teamEntry = teamAssignments.first(where: { $0.$user.id == member.$user.id }) {
                        let teamID = teamEntry.$team.id
                        teamMap[teamID, default: []].append(member)
                    }
                }

                for (teamID, list) in teamMap {
                    teamMap[teamID] = list.shuffled()
                }

                let teamIDs = teamMap.keys.shuffled()
                var index = 0
                while pickOrderMembers.count < members.count {
                    for teamID in teamIDs {
                        if let list = teamMap[teamID], index < list.count {
                            pickOrderMembers.append(list[index])
                        }
                    }
                    index += 1
                }

            } else {
                pickOrderMembers = members.shuffled()
            }

            for (index, member) in pickOrderMembers.enumerated() {
                member.pickOrder = index + 1
                try await member.save(on: req.db)
            }
        }

        // 🎯 First upcoming race
        let firstRace = try await Race.query(on: req.db)
            .filter(\.$seasonID == league.seasonID)
            .filter(\.$completed == false)
            .sort(\.$raceTime)
            .first()

        guard let race = firstRace else {
            throw Abort(.badRequest, reason: "No upcoming races found for the active season.")
        }

        league.status = "active"
        league.initialRaceRound = race.round
        try await league.save(on: req.db)

        // 🗓️ Races from initial round
        let allRaces = try await Race.query(on: req.db)
            .filter(\.$seasonID == league.seasonID)
            .filter(\.$round >= league.initialRaceRound ?? 1)
            .sort(\.$round)
            .all()

        let baseOrder = pickOrderMembers.map { $0.$user.id }

        for (i, race) in allRaces.enumerated() {
            let rotated = Array(baseOrder.dropFirst(i % baseOrder.count) + baseOrder.prefix(i % baseOrder.count))
            let pickOrder = league.mirrorEnabled ? rotated + rotated.reversed() : rotated

            let draft = RaceDraft(
                leagueID: leagueID,
                raceID: try race.requireID(),
                pickOrder: pickOrder,
                mirrorPicks: league.mirrorEnabled,
                status: "pending"
            )
            try await draft.save(on: req.db)

            if i == 0, let firstUserID = pickOrder.first {
                try await NotificationService.notifyDraftTurn(
                    on: req.db,
                    recipientID: firstUserID,
                    league: league,
                    race: race,
                    draftID: try draft.requireID(),
                    pickIndex: 0
                )
            }
        }

        return .ok
    }
    
    func getPickOrderForRace(_ req: Request) async throws -> [Int] {
        let _ = try req.auth.require(User.self)

        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid leagueID/raceID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let draft = try await RaceDraft.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first()
        else {
            throw Abort(.notFound, reason: "Draft not found for that league and race.")
        }

        return draft.pickOrder
    }
    
    func getDraftDeadlines(_ req: Request) async throws -> DraftDeadline {
        let _ = try req.auth.require(User.self)

        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid leagueID/raceID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let race = try await Race.find(raceID, on: req.db),
              let fp1 = race.fp1Time else {
            throw Abort(.notFound, reason: "Race not found or FP1 time missing.")
        }

        guard (try await RaceDraft.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first()) != nil else {
            throw Abort(.notFound, reason: "Draft not found for that race.")
        }

        let firstHalfDeadline = Calendar.current.date(byAdding: .hour, value: -36, to: fp1)!
        let secondHalfDeadline = fp1

        return DraftDeadline(
            raceID: raceID,
            leagueID: leagueID,
            firstHalfDeadline: firstHalfDeadline,
            secondHalfDeadline: secondHalfDeadline
        )
    }

    func getAutopickList(_ req: Request) async throws -> AutopickListResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        let existing = try await PlayerAutopick.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$user.$id == userID)
            .first()

        return AutopickListResponse(driverIDs: existing?.driverOrder ?? [])
    }

    func upsertAutopickList(_ req: Request) async throws -> AutopickListResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let leagueID = req.parameters.get("leagueID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid league ID.")
        }

        let league = try await LeagueAccess.requireMember(req, leagueID: leagueID)
        let data = try req.content.decode(AutopickListRequest.self)

        var seen = Set<Int>()
        let orderedUnique = data.driverIDs.filter { seen.insert($0).inserted }

        if !orderedUnique.isEmpty {
            let validIDs = try await Driver.query(on: req.db)
                .filter(\.$seasonID == league.seasonID)
                .filter(\.$id ~~ orderedUnique)
                .all()
                .map { $0.id }

            let validIDSet = Set(validIDs.compactMap { $0 })
            guard validIDSet.count == orderedUnique.count else {
                throw Abort(.badRequest, reason: "One or more driver IDs are invalid for this league season.")
            }
        }

        if orderedUnique.isEmpty {
            if let existing = try await PlayerAutopick.query(on: req.db)
                .filter(\.$league.$id == leagueID)
                .filter(\.$user.$id == userID)
                .first() {
                try await existing.delete(on: req.db)
            }
            return AutopickListResponse(driverIDs: [])
        }

        if let existing = try await PlayerAutopick.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$user.$id == userID)
            .first() {
            existing.driverOrder = orderedUnique
            try await existing.save(on: req.db)
        } else {
            let autopick = PlayerAutopick(leagueID: leagueID, userID: userID, driverOrder: orderedUnique)
            try await autopick.save(on: req.db)
        }

        return AutopickListResponse(driverIDs: orderedUnique)
    }

    struct RaceDraftResponse: Content {
        struct LeagueRef: Content {
            let id: Int
        }

        let id: Int
        let league: LeagueRef
        let raceID: Int
        let pickOrder: [Int]
        let currentPickIndex: Int
        let mirrorPicks: Bool
        let status: String
        let pickedDriverIDs: [Int?]
        let bannedDriverIDs: [Int]
    }

    func getRaceDraft(_ req: Request) async throws -> RaceDraftResponse {
        let _ = try req.auth.require(User.self)
        guard let leagueID = req.parameters.get("leagueID", as: Int.self),
              let raceID = req.parameters.get("raceID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid leagueID/raceID.")
        }

        _ = try await LeagueAccess.requireMember(req, leagueID: leagueID)

        guard let draft = try await RaceDraft.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first()
        else {
            throw Abort(.notFound, reason: "Draft not found.")
        }
        guard let sql = req.db as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required for draft details.")
        }

        let draftID = try draft.requireID()

        struct PickRow: Decodable {
            let user_id: Int
            let driver_id: Int
            let is_mirror_pick: Bool
        }

        struct BannedRow: Decodable {
            let driver_id: Int
        }

        struct PickKey: Hashable {
            let userID: Int
            let isMirrorPick: Bool
        }

        let pickRows = try await sql.raw("""
            SELECT user_id, driver_id, is_mirror_pick
            FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = false
        """).all(decoding: PickRow.self)

        let bannedRows = try await sql.raw("""
            SELECT DISTINCT driver_id
            FROM player_picks
            WHERE draft_id = \(bind: draftID)
              AND is_banned = true
        """).all(decoding: BannedRow.self)

        var picksByKey: [PickKey: Int] = [:]
        picksByKey.reserveCapacity(pickRows.count)
        for row in pickRows {
            picksByKey[PickKey(userID: row.user_id, isMirrorPick: row.is_mirror_pick)] = row.driver_id
        }

        let pickOrder = draft.pickOrder
        var pickedDriverIDs = Array<Int?>(repeating: nil, count: pickOrder.count)
        var seenUsers = Set<Int>()
        seenUsers.reserveCapacity(pickOrder.count)

        for (index, userID) in pickOrder.enumerated() {
            let isMirrorPick = draft.mirrorPicks && seenUsers.contains(userID)
            if let driverID = picksByKey[PickKey(userID: userID, isMirrorPick: isMirrorPick)] {
                pickedDriverIDs[index] = driverID
            }
            seenUsers.insert(userID)
        }

        let bannedDriverIDs = bannedRows.map { $0.driver_id }.sorted()

        return RaceDraftResponse(
            id: draftID,
            league: RaceDraftResponse.LeagueRef(id: leagueID),
            raceID: draft.raceID,
            pickOrder: pickOrder,
            currentPickIndex: draft.currentPickIndex,
            mirrorPicks: draft.mirrorPicks,
            status: draft.status,
            pickedDriverIDs: pickedDriverIDs,
            bannedDriverIDs: bannedDriverIDs
        )
    }


}

struct CreateLeagueRequest: Content {
    let name: String
    let maxPlayers: Int
    let teamsEnabled: Bool
    let bansEnabled: Bool
    let mirrorEnabled: Bool
}

struct JoinLeagueRequest: Content {
    let code: String
}

func joinLeague(_ req: Request) async throws -> League.Public {
    let user = try req.auth.require(User.self)
    let data = try req.content.decode(JoinLeagueRequest.self)

    guard let league = try await League.query(on: req.db)
        .filter(\.$code == data.code)
        .first() else {
        throw Abort(.notFound, reason: "League with the given code not found.")
    }

    guard league.status.lowercased() == "pending" else {
        throw Abort(.badRequest, reason: "You can only join leagues that are pending.")
    }

    let alreadyMember = try await LeagueMember.query(on: req.db)
        .filter(\.$user.$id == user.requireID())
        .filter(\.$league.$id == league.requireID())
        .first() != nil

    if alreadyMember {
        throw Abort(.conflict, reason: "You are already a member of this league.")
    }

    let memberCount = try await LeagueMember.query(on: req.db)
        .filter(\.$league.$id == league.requireID())
        .count()

    if memberCount >= league.maxPlayers {
        throw Abort(.conflict, reason: "League is already full.")
    }

    let member = LeagueMember(userID: try user.requireID(), leagueID: try league.requireID())
    try await member.save(on: req.db)

    return league.convertToPublic()
}
