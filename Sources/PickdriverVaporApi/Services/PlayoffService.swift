import Fluent
import SQLKit
import Vapor

enum PlayoffService {
    static let selectionDeadlineOffset: TimeInterval = 24 * 3600

    struct StatusResponse: Content {
        let enabled: Bool
        let status: String
        let regularRaceCount: Int
        let playoffRaceIDs: [Int]
        let firstPlayoffRaceID: Int?
        let selectionDeadline: Date?
        let seedOrder: [Int]
        let topGroupSize: Int?
        let selectedPickPositionByUserID: [String: Int]
        let availablePickPositions: [Int]
        let nextSelectorUserID: Int?
        let firstPickOrder: [Int]
    }

    private struct LeaguePlayoffRow: Decodable {
        let id: Int
        let league_id: Int
        let regular_race_count: Int
        let first_race_id: Int
        let playoff_race_ids: [Int]
        let selection_deadline: Date
        let seed_order: [Int]
        let top_group_size: Int
        let first_pick_order: [Int]
        let status: String
    }

    private struct SelectionRow: Decodable {
        let user_id: Int
        let selection_rank: Int
        let pick_position: Int?
    }

    private struct LeagueIDRow: Decodable {
        let league_id: Int
    }

    private struct ExistingDraftState: Decodable {
        let has_picks: Bool
        let has_bans: Bool
    }

    private struct PlayoffIDRow: Decodable {
        let id: Int
    }

    private struct PlayerPointsRow: Decodable {
        let user_id: Int
        let total_points: Double
    }

    private struct Schedule {
        let races: [Race]
        let regularRaceCount: Int
        let regularRaces: [Race]
        let playoffRaces: [Race]

        var playoffsEnabled: Bool {
            !playoffRaces.isEmpty
        }
    }

    static func synchronizeActiveLeagues(on database: any Database, now: Date = Date()) async throws {
        let activeLeagueIDs = try await League.query(on: database)
            .filter(\.$status == "active")
            .all()
            .compactMap(\.id)

        for leagueID in activeLeagueIDs {
            try await synchronizeLeague(leagueID: leagueID, on: database, now: now)
        }
    }

    /// Rebuilds only drafts that are still part of the regular season. Once the
    /// regular season is complete, a persisted playoff record freezes the bracket.
    static func synchronizeLeague(leagueID: Int, on database: any Database, now: Date = Date()) async throws {
        guard let league = try await League.find(leagueID, on: database),
              league.status == "active",
              league.initialRaceRound != nil else {
            return
        }

        let schedule = try await makeSchedule(for: league, on: database)
        let playoff = try await playoffRow(leagueID: leagueID, on: database)

        if let playoff,
           playoff.status == "selecting",
           try await discardUnselectedPlayoffIfScheduleChanged(
               playoff: playoff,
               schedule: schedule,
               on: database
           ) {
            try await synchronizeLeague(leagueID: leagueID, on: database, now: now)
            return
        }

        if playoff == nil {
            try await synchronizeUnfrozenDrafts(
                league: league,
                schedule: schedule,
                on: database
            )

            guard schedule.playoffsEnabled,
                  schedule.regularRaces.allSatisfy({ $0.effectiveStatus == .completed }),
                  let firstPlayoffRace = schedule.playoffRaces.first,
                  let fp1 = firstPlayoffRace.fp1Time else {
                return
            }

            let seedOrder = try await playoffSeedOrder(
                leagueID: leagueID,
                regularRaceIDs: schedule.regularRaces.compactMap(\.id),
                on: database
            )
            guard !seedOrder.isEmpty else {
                return
            }

            let topGroupSize = (seedOrder.count + 1) / 2
            let deadline = fp1.addingTimeInterval(-selectionDeadlineOffset)
            let firstPlayoffRaceID = try firstPlayoffRace.requireID()
            let playoffRaceIDs = try schedule.playoffRaces.map { try $0.requireID() }
            let createdPlayoff = try await database.transaction { transaction in
                if let existingPlayoff = try await playoffRow(leagueID: leagueID, on: transaction) {
                    return existingPlayoff
                }

                return try await createPlayoff(
                    leagueID: leagueID,
                    regularRaceCount: schedule.regularRaceCount,
                    firstRaceID: firstPlayoffRaceID,
                    playoffRaceIDs: playoffRaceIDs,
                    selectionDeadline: deadline,
                    seedOrder: seedOrder,
                    topGroupSize: topGroupSize,
                    on: transaction
                )
            }

            if now >= createdPlayoff.selection_deadline {
                try await finalizeExpiredSelection(leagueID: leagueID, on: database, now: now)
            }
            return
        }

        if playoff?.status == "selecting", now >= playoff?.selection_deadline ?? now {
            try await finalizeExpiredSelection(leagueID: leagueID, on: database, now: now)
        }
    }

    static func status(leagueID: Int, on database: any Database, now: Date = Date()) async throws -> StatusResponse {
        try await synchronizeLeague(leagueID: leagueID, on: database, now: now)

        guard let league = try await League.find(leagueID, on: database),
              league.status == "active",
              league.initialRaceRound != nil else {
            return StatusResponse(
                enabled: false,
                status: "not_available",
                regularRaceCount: 0,
                playoffRaceIDs: [],
                firstPlayoffRaceID: nil,
                selectionDeadline: nil,
                seedOrder: [],
                topGroupSize: nil,
                selectedPickPositionByUserID: [:],
                availablePickPositions: [],
                nextSelectorUserID: nil,
                firstPickOrder: []
            )
        }

        let schedule = try await makeSchedule(for: league, on: database)
        let playoff = try await playoffRow(leagueID: leagueID, on: database)
        guard schedule.playoffsEnabled || playoff != nil else {
            return StatusResponse(
                enabled: false,
                status: "not_applicable",
                regularRaceCount: schedule.regularRaceCount,
                playoffRaceIDs: [],
                firstPlayoffRaceID: nil,
                selectionDeadline: nil,
                seedOrder: [],
                topGroupSize: nil,
                selectedPickPositionByUserID: [:],
                availablePickPositions: [],
                nextSelectorUserID: nil,
                firstPickOrder: []
            )
        }

        let scheduledPlayoffRaceIDs = try schedule.playoffRaces.map { try $0.requireID() }
        guard let playoff else {
            let deadline = schedule.playoffRaces.first?.fp1Time?.addingTimeInterval(-selectionDeadlineOffset)
            return StatusResponse(
                enabled: true,
                status: "regular_season",
                regularRaceCount: schedule.regularRaceCount,
                playoffRaceIDs: scheduledPlayoffRaceIDs,
                firstPlayoffRaceID: scheduledPlayoffRaceIDs.first,
                selectionDeadline: deadline,
                seedOrder: [],
                topGroupSize: nil,
                selectedPickPositionByUserID: [:],
                availablePickPositions: [],
                nextSelectorUserID: nil,
                firstPickOrder: []
            )
        }

        let selections = try await selectionRows(playoffID: playoff.id, on: database)
        let selectedByUserID = Dictionary(
            uniqueKeysWithValues: selections.compactMap { row in
                row.pick_position.map { (String(row.user_id), $0) }
            }
        )
        let usedPositions = Set(selections.compactMap(\.pick_position))
        let availablePositions = Array(1...playoff.seed_order.count).filter { !usedPositions.contains($0) }
        let selectedUserIDs = Set(selections.compactMap { $0.pick_position == nil ? nil : $0.user_id })
        let nextSelector = playoff.status == "selecting"
            ? playoff.seed_order.first(where: { !selectedUserIDs.contains($0) })
            : nil

        return StatusResponse(
            enabled: true,
            status: playoff.status,
            regularRaceCount: playoff.regular_race_count,
            playoffRaceIDs: playoff.playoff_race_ids,
            firstPlayoffRaceID: playoff.first_race_id,
            selectionDeadline: playoff.selection_deadline,
            seedOrder: playoff.seed_order,
            topGroupSize: playoff.top_group_size,
            selectedPickPositionByUserID: selectedByUserID,
            availablePickPositions: availablePositions,
            nextSelectorUserID: nextSelector,
            firstPickOrder: playoff.first_pick_order
        )
    }

    static func selectPickPosition(
        leagueID: Int,
        userID: Int,
        pickPosition: Int,
        on database: any Database,
        now: Date = Date()
    ) async throws {
        try await synchronizeLeague(leagueID: leagueID, on: database, now: now)

        let finalizedAfterDeadline = try await database.transaction { transaction -> Bool in
            guard let sql = transaction as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for playoff pick-order selection.")
            }
            guard let playoff = try await lockedPlayoffRow(leagueID: leagueID, sql: sql) else {
                throw Abort(.conflict, reason: "Playoff pick-order selection is not available yet.")
            }
            guard playoff.status == "selecting" else {
                throw Abort(.conflict, reason: "The playoff pick order has already been finalized.")
            }

            if now >= playoff.selection_deadline {
                try await assignRemainingPositions(playoff: playoff, sql: sql, now: now, randomize: true)
                try await finalizeSelection(playoff: playoff, on: transaction, sql: sql, now: now)
                return true
            }

            let selections = try await selectionRows(playoffID: playoff.id, on: transaction)
            let selectedUserIDs = Set(selections.compactMap { $0.pick_position == nil ? nil : $0.user_id })
            guard let nextSelectorUserID = playoff.seed_order.first(where: { !selectedUserIDs.contains($0) }),
                  nextSelectorUserID == userID else {
                throw Abort(.forbidden, reason: "It is not your turn to choose a playoff pick position.")
            }

            guard let userRank = playoff.seed_order.firstIndex(of: userID) else {
                throw Abort(.forbidden, reason: "You are not eligible for this playoff pick order.")
            }
            let allowedPositions = allowedPickPositions(
                selectionRank: userRank,
                topGroupSize: playoff.top_group_size,
                memberCount: playoff.seed_order.count
            )
            guard allowedPositions.contains(pickPosition) else {
                throw Abort(.badRequest, reason: "That pick position is outside your playoff group.")
            }
            guard !Set(selections.compactMap(\.pick_position)).contains(pickPosition) else {
                throw Abort(.conflict, reason: "That playoff pick position has already been selected.")
            }

            try await sql.raw("""
                UPDATE league_playoff_pick_selections
                SET pick_position = \(bind: pickPosition), selected_at = NOW()
                WHERE playoff_id = \(bind: playoff.id)
                  AND user_id = \(bind: userID)
                  AND pick_position IS NULL
            """).run()

            let updatedSelections = try await selectionRows(playoffID: playoff.id, on: transaction)
            if updatedSelections.allSatisfy({ $0.pick_position != nil }) {
                try await finalizeSelection(playoff: playoff, on: transaction, sql: sql, now: now)
                return false
            }

            // The last player receives the sole remaining position in their group.
            if updatedSelections.compactMap(\.pick_position).count == playoff.seed_order.count - 1 {
                try await assignRemainingPositions(playoff: playoff, sql: sql, now: now, randomize: false)
                try await finalizeSelection(playoff: playoff, on: transaction, sql: sql, now: now)
            }

            return false
        }

        if finalizedAfterDeadline {
            throw Abort(.conflict, reason: "The playoff pick-order selection deadline has passed.")
        }
    }

    static func requireDraftReady(leagueID: Int, raceID: Int, on database: any Database, now: Date = Date()) async throws {
        try await synchronizeLeague(leagueID: leagueID, on: database, now: now)
        guard let league = try await League.find(leagueID, on: database),
              league.initialRaceRound != nil else {
            return
        }

        let playoff = try await playoffRow(leagueID: leagueID, on: database)
        guard let playoff else {
            return
        }
        guard Set(playoff.playoff_race_ids).contains(raceID) else {
            return
        }
        guard playoff.status == "finalized" else {
            throw Abort(.conflict, reason: "The playoff pick order is still pending.")
        }
    }

    /// The player-selected order can remain open until FP1 - 24h, which is
    /// later than the regular FP1 - 36h first-half deadline. The first
    /// playoff draft therefore keeps every slot manually playable until FP1;
    /// later playoff drafts retain the normal deadline split.
    static func firstHalfDraftDeadline(
        leagueID: Int,
        raceID: Int,
        fp1Time: Date,
        on database: any Database
    ) async throws -> Date {
        guard let playoff = try await playoffRow(leagueID: leagueID, on: database),
              playoff.status == "finalized",
              playoff.first_race_id == raceID else {
            return fp1Time.addingTimeInterval(-36 * 3600)
        }

        return fp1Time
    }

    /// A finalized bracket is immutable. Cancellation cleanup uses this to
    /// retain the historical playoff order of a cancelled race while it
    /// recalculates only ordinary, unfrozen draft rotations.
    static func isFinalizedPlayoffRace(
        leagueID: Int,
        raceID: Int,
        on database: any Database
    ) async throws -> Bool {
        guard let playoff = try await playoffRow(leagueID: leagueID, on: database) else {
            return false
        }
        return playoff.status == "finalized" && playoff.playoff_race_ids.contains(raceID)
    }

    static func processExpiredSelections(app: Application) async {
        do {
            try await synchronizeActiveLeagues(on: app.db)
            guard let sql = app.db as? (any SQLDatabase) else {
                app.logger.warning("PlayoffService: SQLDatabase required to process selection deadlines")
                return
            }

            let expiredLeagueIDs = try await sql.raw("""
                SELECT league_id
                FROM league_playoffs
                WHERE status = \(bind: "selecting")
                  AND selection_deadline <= NOW()
            """).all(decoding: LeagueIDRow.self).map(\.league_id)

            for leagueID in expiredLeagueIDs {
                do {
                    try await finalizeExpiredSelection(leagueID: leagueID, on: app.db, now: Date())
                } catch {
                    app.logger.error("PlayoffService: failed to finalize league \(leagueID): \(error)")
                }
            }
        } catch {
            app.logger.error("PlayoffService: failed to process selection deadlines: \(error)")
        }
    }

    private static func makeSchedule(for league: League, on database: any Database) async throws -> Schedule {
        guard let initialRaceRound = league.initialRaceRound else {
            return Schedule(races: [], regularRaceCount: 0, regularRaces: [], playoffRaces: [])
        }

        let playableRaces = try await Race.query(on: database)
            .filter(\.$seasonID == league.seasonID)
            .filter(\.$round >= initialRaceRound)
            .filter(\.$status != Race.Status.cancelled.rawValue)
            .sort(\.$round)
            .all()

        let leagueID = try league.requireID()
        let playerCount = try await LeagueMember.query(on: database)
            .filter(\.$league.$id == leagueID)
            .count()
        guard playerCount > 0 else {
            return Schedule(races: playableRaces, regularRaceCount: playableRaces.count, regularRaces: playableRaces, playoffRaces: [])
        }

        let completedRotations = playableRaces.count / playerCount
        let playoffRaceCount = completedRotations > 0 ? playableRaces.count % playerCount : 0
        let regularRaceCount = playableRaces.count - playoffRaceCount

        return Schedule(
            races: playableRaces,
            regularRaceCount: regularRaceCount,
            regularRaces: Array(playableRaces.prefix(regularRaceCount)),
            playoffRaces: Array(playableRaces.dropFirst(regularRaceCount))
        )
    }

    private static func synchronizeUnfrozenDrafts(
        league: League,
        schedule: Schedule,
        on database: any Database
    ) async throws {
        let leagueID = try league.requireID()
        let baseOrder = try await LeagueMember.query(on: database)
            .filter(\.$league.$id == leagueID)
            .sort(\.$pickOrder)
            .all()
            .map { $0.$user.id }
        guard !baseOrder.isEmpty else {
            return
        }

        for (index, race) in schedule.races.enumerated() {
            let raceID = try race.requireID()
            let isRegularRace = index < schedule.regularRaceCount
            let rotated = rotate(baseOrder, by: index)
            let expectedOrder = league.mirrorEnabled ? rotated + rotated.reversed() : rotated

            if let draft = try await RaceDraft.query(on: database)
                .filter(\.$league.$id == leagueID)
                .filter(\.$raceID == raceID)
                .first() {
                guard race.effectiveStatus != .completed else {
                    continue
                }

                let draftID = try draft.requireID()
                let activity = try await draftActivity(draftID: draftID, on: database)
                if isRegularRace {
                    let needsReconciliation = draft.pickOrder != expectedOrder || draft.status == "playoff_pending"
                    if needsReconciliation,
                       !activity.has_picks,
                       !activity.has_bans,
                       draft.currentPickIndex == 0 {
                        draft.pickOrder = expectedOrder
                        draft.currentPickIndex = 0
                        draft.status = "pending"
                        draft.protectedRepickUserID = nil
                        draft.protectedRepickPickIndex = nil
                        draft.protectedRepickDeadline = nil
                        try await draft.save(on: database)
                    }
                } else if !activity.has_picks && !activity.has_bans {
                    draft.pickOrder = []
                    draft.currentPickIndex = 0
                    draft.status = "playoff_pending"
                    draft.protectedRepickUserID = nil
                    draft.protectedRepickPickIndex = nil
                    draft.protectedRepickDeadline = nil
                    try await draft.save(on: database)
                }
            } else {
                let draft = RaceDraft(
                    leagueID: leagueID,
                    raceID: raceID,
                    pickOrder: isRegularRace ? expectedOrder : [],
                    mirrorPicks: league.mirrorEnabled,
                    status: isRegularRace ? "pending" : "playoff_pending"
                )
                try await draft.save(on: database)
            }
        }
    }

    private static func createPlayoff(
        leagueID: Int,
        regularRaceCount: Int,
        firstRaceID: Int,
        playoffRaceIDs: [Int],
        selectionDeadline: Date,
        seedOrder: [Int],
        topGroupSize: Int,
        on database: any Database
    ) async throws -> LeaguePlayoffRow {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required to create a playoff.")
        }

        let inserted = try await sql.raw("""
            INSERT INTO league_playoffs (
                league_id,
                regular_race_count,
                first_race_id,
                playoff_race_ids,
                selection_deadline,
                seed_order,
                top_group_size,
                first_pick_order,
                status
            )
            VALUES (
                \(bind: leagueID),
                \(bind: regularRaceCount),
                \(bind: firstRaceID),
                \(bind: playoffRaceIDs),
                \(bind: selectionDeadline),
                \(bind: seedOrder),
                \(bind: topGroupSize),
                \(bind: [Int]()),
                \(bind: "selecting")
            )
            ON CONFLICT (league_id) DO NOTHING
            RETURNING id
        """).first(decoding: PlayoffIDRow.self)

        let playoff = try await playoffRow(leagueID: leagueID, on: database)
        guard let playoff else {
            throw Abort(.internalServerError, reason: "Could not create playoff state.")
        }

        if inserted != nil {
            for (rank, userID) in seedOrder.enumerated() {
                try await sql.raw("""
                    INSERT INTO league_playoff_pick_selections (playoff_id, user_id, selection_rank)
                    VALUES (\(bind: playoff.id), \(bind: userID), \(bind: rank))
                """).run()
            }
        }

        return playoff
    }

    /// Until a player has chosen a position, an added/cancelled race (or an
    /// FP1 change) must still be reflected in the boundary and deadline. Once
    /// any choice exists, changing the frozen standings or group sizes would
    /// invalidate a player's choice, so that bracket remains authoritative.
    private static func discardUnselectedPlayoffIfScheduleChanged(
        playoff: LeaguePlayoffRow,
        schedule: Schedule,
        on database: any Database
    ) async throws -> Bool {
        let expectedRaceIDs = try schedule.playoffRaces.map { try $0.requireID() }
        let expectedFirstRaceID = expectedRaceIDs.first
        let expectedDeadline = schedule.playoffRaces.first?.fp1Time?.addingTimeInterval(-selectionDeadlineOffset)
        let deadlineChanged: Bool = {
            guard let expectedDeadline else {
                return true
            }
            return abs(playoff.selection_deadline.timeIntervalSince(expectedDeadline)) > 0.001
        }()

        let scheduleChanged = playoff.regular_race_count != schedule.regularRaceCount
            || playoff.playoff_race_ids != expectedRaceIDs
            || playoff.first_race_id != expectedFirstRaceID
            || deadlineChanged
        guard scheduleChanged else {
            return false
        }

        return try await database.transaction { transaction in
            guard let sql = transaction as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required to reconcile a playoff schedule.")
            }
            guard let lockedPlayoff = try await lockedPlayoffRow(leagueID: playoff.league_id, sql: sql),
                  lockedPlayoff.status == "selecting" else {
                return false
            }

            let selections = try await selectionRows(playoffID: lockedPlayoff.id, on: sql)
            guard selections.allSatisfy({ $0.pick_position == nil }) else {
                return false
            }

            try await sql.raw("DELETE FROM league_playoffs WHERE id = \(bind: lockedPlayoff.id)").run()
            return true
        }
    }

    private static func finalizeExpiredSelection(
        leagueID: Int,
        on database: any Database,
        now: Date
    ) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required to finalize a playoff.")
            }
            guard let playoff = try await lockedPlayoffRow(leagueID: leagueID, sql: sql),
                  playoff.status == "selecting",
                  now >= playoff.selection_deadline else {
                return
            }

            try await assignRemainingPositions(playoff: playoff, sql: sql, now: now, randomize: true)
            try await finalizeSelection(playoff: playoff, on: transaction, sql: sql, now: now)
        }
    }

    private static func finalizeSelection(
        playoff: LeaguePlayoffRow,
        on database: any Database,
        sql: any SQLDatabase,
        now: Date
    ) async throws {
        let selections = try await selectionRows(playoffID: playoff.id, on: sql)
        guard selections.allSatisfy({ $0.pick_position != nil }) else {
            throw Abort(.internalServerError, reason: "Cannot finalize a playoff with unassigned pick positions.")
        }

        let orderByPosition: [Int: Int] = Dictionary(uniqueKeysWithValues: selections.compactMap { row in
            row.pick_position.map { ($0, row.user_id) }
        })
        let memberCount = playoff.seed_order.count
        guard orderByPosition.count == memberCount else {
            throw Abort(.internalServerError, reason: "Playoff pick positions are incomplete.")
        }

        let topOrder = try (1...playoff.top_group_size).map { position -> Int in
            guard let userID = orderByPosition[position] else {
                throw Abort(.internalServerError, reason: "Top playoff group is incomplete.")
            }
            return userID
        }
        let bottomOrder = try (playoff.top_group_size + 1...memberCount).map { position -> Int in
            guard let userID = orderByPosition[position] else {
                throw Abort(.internalServerError, reason: "Bottom playoff group is incomplete.")
            }
            return userID
        }

        guard let league = try await League.find(playoff.league_id, on: database) else {
            throw Abort(.notFound, reason: "League not found while finalizing playoffs.")
        }
        let playoffRaces = try await Race.query(on: database)
            .filter(\.$id ~~ playoff.playoff_race_ids)
            .filter(\.$status != Race.Status.cancelled.rawValue)
            .sort(\.$round)
            .all()
        guard !playoffRaces.isEmpty else {
            throw Abort(.conflict, reason: "The playoff schedule is no longer available.")
        }

        for (offset, race) in playoffRaces.enumerated() {
            let firstGroup = rotate(topOrder, by: offset)
            let secondGroup = rotate(bottomOrder, by: offset)
            let forwardOrder: [Int] = Array(firstGroup) + Array(secondGroup)
            let pickOrder: [Int] = league.mirrorEnabled
                ? forwardOrder + Array(firstGroup.reversed()) + Array(secondGroup.reversed())
                : forwardOrder
            try await applyPlayoffPickOrder(
                leagueID: playoff.league_id,
                raceID: try race.requireID(),
                pickOrder: pickOrder,
                mirrorPicks: league.mirrorEnabled,
                on: database,
                sql: sql
            )
        }

        let firstGroup = topOrder
        let secondGroup = bottomOrder
        let firstPickOrder = league.mirrorEnabled
            ? firstGroup + secondGroup + firstGroup.reversed() + secondGroup.reversed()
            : firstGroup + secondGroup

        try await sql.raw("""
            UPDATE league_playoffs
            SET status = \(bind: "finalized"),
                first_pick_order = \(bind: firstPickOrder),
                updated_at = NOW()
            WHERE id = \(bind: playoff.id)
        """).run()
    }

    private static func assignRemainingPositions(
        playoff: LeaguePlayoffRow,
        sql: any SQLDatabase,
        now: Date,
        randomize: Bool
    ) async throws {
        let selections = try await selectionRows(playoffID: playoff.id, on: sql)
        var usedPositions: Set<Int> = Set(selections.compactMap(\.pick_position))

        for row in selections.sorted(by: { $0.selection_rank < $1.selection_rank }) where row.pick_position == nil {
            let allowed = allowedPickPositions(
                selectionRank: row.selection_rank,
                topGroupSize: playoff.top_group_size,
                memberCount: playoff.seed_order.count
            ).filter { !usedPositions.contains($0) }
            guard !allowed.isEmpty else {
                throw Abort(.internalServerError, reason: "No playoff pick position remains for a player.")
            }
            let position = randomize ? allowed.randomElement()! : allowed[0]

            try await sql.raw("""
                UPDATE league_playoff_pick_selections
                SET pick_position = \(bind: position), selected_at = \(bind: now)
                WHERE playoff_id = \(bind: playoff.id)
                  AND user_id = \(bind: row.user_id)
                  AND pick_position IS NULL
            """).run()
            usedPositions.insert(position)
        }
    }

    private static func applyPlayoffPickOrder(
        leagueID: Int,
        raceID: Int,
        pickOrder: [Int],
        mirrorPicks: Bool,
        on database: any Database,
        sql: any SQLDatabase
    ) async throws {
        let existingDraft = try await RaceDraft.query(on: database)
            .filter(\.$league.$id == leagueID)
            .filter(\.$raceID == raceID)
            .first()

        if let existingDraft {
            let draftID = try existingDraft.requireID()
            let activity = try await draftActivity(draftID: draftID, on: sql)
            guard !activity.has_picks && !activity.has_bans && existingDraft.currentPickIndex == 0 else {
                throw Abort(.conflict, reason: "A playoff draft has already started and cannot be reordered.")
            }
            existingDraft.pickOrder = pickOrder
            existingDraft.mirrorPicks = mirrorPicks
            existingDraft.status = "pending"
            existingDraft.protectedRepickUserID = nil
            existingDraft.protectedRepickPickIndex = nil
            existingDraft.protectedRepickDeadline = nil
            try await existingDraft.save(on: database)
        } else {
            let draft = RaceDraft(
                leagueID: leagueID,
                raceID: raceID,
                pickOrder: pickOrder,
                mirrorPicks: mirrorPicks,
                status: "pending"
            )
            try await draft.save(on: database)
        }
    }

    private static func playoffSeedOrder(
        leagueID: Int,
        regularRaceIDs: [Int],
        on database: any Database
    ) async throws -> [Int] {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required to calculate playoff standings.")
        }

        return try await sql.raw("""
            SELECT
                lm.user_id,
                COALESCE(points.total_points, 0.0) AS total_points
            FROM league_members lm
            LEFT JOIN (
                SELECT
                    pp.user_id,
                    SUM(
                        CASE WHEN pp.is_autopick THEN rr.points::double precision * 0.5
                             ELSE rr.points::double precision
                        END
                    ) AS total_points
                FROM player_picks pp
                JOIN race_drafts rd ON rd.id = pp.draft_id
                JOIN races r ON r.id = rd.race_id
                JOIN race_results rr ON rr.race_id = r.id AND rr.driver_id = pp.driver_id
                WHERE rd.league_id = \(bind: leagueID)
                  AND r.id = ANY(\(bind: regularRaceIDs))
                  AND r.completed = true
                  AND pp.is_banned = false
                GROUP BY pp.user_id
            ) points ON points.user_id = lm.user_id
            WHERE lm.league_id = \(bind: leagueID)
            ORDER BY total_points DESC, lm.user_id ASC
        """).all(decoding: PlayerPointsRow.self).map(\.user_id)
    }

    private static func playoffRow(leagueID: Int, on database: any Database) async throws -> LeaguePlayoffRow? {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required for playoff state.")
        }
        return try await sql.raw("""
            SELECT
                id,
                league_id,
                regular_race_count,
                first_race_id,
                playoff_race_ids,
                selection_deadline,
                seed_order,
                top_group_size,
                first_pick_order,
                status
            FROM league_playoffs
            WHERE league_id = \(bind: leagueID)
            LIMIT 1
        """).first(decoding: LeaguePlayoffRow.self)
    }

    private static func lockedPlayoffRow(leagueID: Int, sql: any SQLDatabase) async throws -> LeaguePlayoffRow? {
        try await sql.raw("""
            SELECT
                id,
                league_id,
                regular_race_count,
                first_race_id,
                playoff_race_ids,
                selection_deadline,
                seed_order,
                top_group_size,
                first_pick_order,
                status
            FROM league_playoffs
            WHERE league_id = \(bind: leagueID)
            FOR UPDATE
        """).first(decoding: LeaguePlayoffRow.self)
    }

    private static func selectionRows(playoffID: Int, on database: any Database) async throws -> [SelectionRow] {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required for playoff selections.")
        }
        return try await selectionRows(playoffID: playoffID, on: sql)
    }

    private static func selectionRows(playoffID: Int, on sql: any SQLDatabase) async throws -> [SelectionRow] {
        return try await sql.raw("""
            SELECT user_id, selection_rank, pick_position
            FROM league_playoff_pick_selections
            WHERE playoff_id = \(bind: playoffID)
            ORDER BY selection_rank ASC
        """).all(decoding: SelectionRow.self)
    }

    private static func draftActivity(draftID: Int, on database: any Database) async throws -> ExistingDraftState {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "SQLDatabase required for draft state.")
        }
        return try await draftActivity(draftID: draftID, on: sql)
    }

    private static func draftActivity(draftID: Int, on sql: any SQLDatabase) async throws -> ExistingDraftState {
        let activity = try await sql.raw("""
            SELECT
                EXISTS (SELECT 1 FROM player_picks WHERE draft_id = \(bind: draftID)) AS has_picks,
                EXISTS (SELECT 1 FROM player_bans WHERE draft_id = \(bind: draftID)) AS has_bans
        """).first(decoding: ExistingDraftState.self)
        guard let activity else {
            throw Abort(.notFound, reason: "Draft not found.")
        }
        return activity
    }

    private static func allowedPickPositions(
        selectionRank: Int,
        topGroupSize: Int,
        memberCount: Int
    ) -> [Int] {
        if selectionRank < topGroupSize {
            return Array(1...topGroupSize)
        }
        return Array(topGroupSize + 1...memberCount)
    }

    private static func rotate(_ values: [Int], by offset: Int) -> [Int] {
        guard !values.isEmpty else {
            return []
        }
        let normalizedOffset = offset % values.count
        return Array(values.dropFirst(normalizedOffset) + values.prefix(normalizedOffset))
    }
}
