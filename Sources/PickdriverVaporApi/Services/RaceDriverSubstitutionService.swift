import Fluent
import SQLKit
import Vapor

enum RaceDriverSubstitutionService {
    struct Request: Content {
        let dryRun: Bool?
        let substitutions: [RaceDriverSubstitutionPolicy.Definition]
    }

    struct RosterEntry: Content, Equatable {
        let driverID: Int
        let f1TeamID: Int
        let status: String
    }

    struct PickChange: Content, Equatable {
        let pickIndex: Int
        let userID: Int
        let previousDriverID: Int?
        let previousOriginalDriverID: Int?
        let effectiveDriverID: Int?
        let originalDriverID: Int?
    }

    struct DraftReconciliation: Content {
        let draftID: Int
        let state: String
        let revisionBefore: Int
        let revisionAfter: Int
        let changes: [PickChange]
    }

    struct Response: Content {
        let raceID: Int
        let dryRun: Bool
        let roster: [RosterEntry]
        let drafts: [DraftReconciliation]
    }

    private struct RaceRow: Decodable {
        let season_id: Int
    }

    private struct DriverRow: Decodable {
        let id: Int
        let f1_team_id: Int
        let active: Bool
    }

    private struct IDRow: Decodable {
        let id: Int
    }

    private struct DraftRow: Decodable {
        let id: Int
        let pick_order: [Int]
        let mirror_picks: Bool
        let resolution_state: String
        let resolution_revision: Int
    }

    private struct SnapshotRow: Decodable {
        let user_id: Int
        let driver_order: [Int]
    }

    private struct BanRow: Decodable {
        let target_user_id: Int
        let target_driver_id: Int
    }

    private struct SlotRow: Decodable {
        let pick_index: Int
        let user_id: Int
        let driver_id: Int?
        let original_driver_id: Int?
    }

    private struct Assignment {
        let pickIndex: Int
        let userID: Int
        let effectiveDriverID: Int?
        let originalDriverID: Int?
    }

    static func reconcile(
        raceID: Int,
        request: Request,
        on database: any Database
    ) async throws -> Response {
        if request.dryRun ?? false {
            guard let sql = database as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for race substitutions.")
            }
            return try await reconcile(
                raceID: raceID,
                definitions: request.substitutions,
                dryRun: true,
                sql: sql
            )
        }

        return try await database.transaction { tx in
            guard let sql = tx as? (any SQLDatabase) else {
                throw Abort(.internalServerError, reason: "SQLDatabase required for race substitutions.")
            }
            return try await reconcile(
                raceID: raceID,
                definitions: request.substitutions,
                dryRun: false,
                sql: sql
            )
        }
    }

    private static func reconcile(
        raceID: Int,
        definitions: [RaceDriverSubstitutionPolicy.Definition],
        dryRun: Bool,
        sql: any SQLDatabase
    ) async throws -> Response {
        guard let race = try await sql.raw("""
            SELECT season_id
            FROM races
            WHERE id = \(bind: raceID)
        """).first(decoding: RaceRow.self) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        let drivers = try await sql.raw("""
            SELECT id, f1_team_id, active
            FROM drivers
            WHERE season_id = \(bind: race.season_id)
            ORDER BY id
        """).all(decoding: DriverRow.self)
        let driverByID = Dictionary(uniqueKeysWithValues: drivers.map { ($0.id, $0) })
        let teamIDs = Set(try await sql.raw("""
            SELECT id
            FROM f1_teams
            WHERE season_id = \(bind: race.season_id)
        """).all(decoding: IDRow.self).map(\.id))

        try validate(definitions: definitions, driverByID: driverByID, teamIDs: teamIDs)
        let roster = buildRoster(drivers: drivers, definitions: definitions)

        let legacyDraftIDs = try await sql.raw("""
            SELECT id
            FROM race_drafts
            WHERE race_id = \(bind: raceID)
              AND gameplay_version <> \(bind: DraftGameplayVersion.v2.rawValue)
        """).all(decoding: IDRow.self).map(\.id)
        if !legacyDraftIDs.isEmpty {
            throw Abort(
                .conflict,
                reason: "Race substitutions require V2 drafts. Unsupported legacy draft IDs: \(legacyDraftIDs)."
            )
        }

        let lockClause: SQLQueryString = dryRun ? "" : "FOR UPDATE"
        let drafts = try await sql.raw("""
            SELECT id, pick_order, mirror_picks, resolution_state, resolution_revision
            FROM race_drafts
            WHERE race_id = \(bind: raceID)
              AND gameplay_version = \(bind: DraftGameplayVersion.v2.rawValue)
            ORDER BY id
            \(lockClause)
        """).all(decoding: DraftRow.self)

        var reconciliations: [DraftReconciliation] = []
        reconciliations.reserveCapacity(drafts.count)

        for draft in drafts {
            let currentSlots = try await loadSlots(draftID: draft.id, sql: sql)
            let assignments = try await resolveAssignments(
                draft: draft,
                definitions: definitions,
                sql: sql
            )
            let changes = changes(from: currentSlots, to: assignments)
            let canReconcile = draft.resolution_state == V2DraftResolutionState.resolved.rawValue
                || draft.resolution_state == V2DraftResolutionState.finalized.rawValue
            let nextRevision = canReconcile && !changes.isEmpty
                ? draft.resolution_revision + 1
                : draft.resolution_revision

            if !dryRun, canReconcile, !changes.isEmpty {
                try await replaceSlots(
                    draft: draft,
                    assignments: assignments,
                    revision: nextRevision,
                    sql: sql
                )
            }

            reconciliations.append(DraftReconciliation(
                draftID: draft.id,
                state: draft.resolution_state,
                revisionBefore: draft.resolution_revision,
                revisionAfter: nextRevision,
                changes: canReconcile ? changes : []
            ))
        }

        if !dryRun {
            try await replaceConfiguration(
                raceID: raceID,
                definitions: definitions,
                roster: roster,
                sql: sql
            )
        }

        return Response(
            raceID: raceID,
            dryRun: dryRun,
            roster: roster,
            drafts: reconciliations
        )
    }

    private static func validate(
        definitions: [RaceDriverSubstitutionPolicy.Definition],
        driverByID: [Int: DriverRow],
        teamIDs: Set<Int>
    ) throws {
        var outgoing = Set<Int>()
        var incoming = Set<Int>()
        var edgeByOutgoing: [Int: Int] = [:]

        for definition in definitions {
            guard definition.outgoingDriverID != definition.incomingDriverID else {
                throw Abort(.badRequest, reason: "A driver cannot substitute themself.")
            }
            guard driverByID[definition.outgoingDriverID] != nil,
                  driverByID[definition.incomingDriverID] != nil else {
                throw Abort(.badRequest, reason: "Every substitution driver must belong to the race season.")
            }
            guard teamIDs.contains(definition.f1TeamID) else {
                throw Abort(.badRequest, reason: "Every substitution team must belong to the race season.")
            }
            guard outgoing.insert(definition.outgoingDriverID).inserted else {
                throw Abort(.badRequest, reason: "A driver can have only one replacement in a race.")
            }
            guard incoming.insert(definition.incomingDriverID).inserted else {
                throw Abort(.badRequest, reason: "A replacement driver can fill only one seat in a race.")
            }
            edgeByOutgoing[definition.outgoingDriverID] = definition.incomingDriverID
        }

        for start in edgeByOutgoing.keys {
            var visited = Set<Int>()
            var current: Int? = start
            while let driverID = current, let next = edgeByOutgoing[driverID] {
                guard visited.insert(driverID).inserted else {
                    throw Abort(.badRequest, reason: "Race substitution chains cannot contain cycles.")
                }
                current = next
            }
        }
    }

    private static func buildRoster(
        drivers: [DriverRow],
        definitions: [RaceDriverSubstitutionPolicy.Definition]
    ) -> [RosterEntry] {
        let outgoing = Set(definitions.map(\.outgoingDriverID))
        let incomingByDriver = Dictionary(uniqueKeysWithValues: definitions.map {
            ($0.incomingDriverID, $0.f1TeamID)
        })

        return drivers.map { driver in
            if let teamID = incomingByDriver[driver.id] {
                return RosterEntry(driverID: driver.id, f1TeamID: teamID, status: "entered")
            }
            if outgoing.contains(driver.id) {
                return RosterEntry(driverID: driver.id, f1TeamID: driver.f1_team_id, status: "withdrawn")
            }
            return RosterEntry(
                driverID: driver.id,
                f1TeamID: driver.f1_team_id,
                status: driver.active ? "entered" : "reserve"
            )
        }
    }

    private static func resolveAssignments(
        draft: DraftRow,
        definitions: [RaceDriverSubstitutionPolicy.Definition],
        sql: any SQLDatabase
    ) async throws -> [Assignment] {
        guard draft.resolution_state != V2DraftResolutionState.collecting.rawValue else {
            return []
        }

        let snapshots = try await sql.raw("""
            SELECT user_id, driver_order
            FROM draft_pick_preference_snapshots
            WHERE draft_id = \(bind: draft.id)
        """).all(decoding: SnapshotRow.self)
        let preferencesByUser = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.user_id, $0.driver_order) })

        let bans = try await sql.raw("""
            SELECT target_user_id, target_driver_id
            FROM v2_draft_bans
            WHERE draft_id = \(bind: draft.id)
        """).all(decoding: BanRow.self)
        let bannedByUser = Dictionary(grouping: bans, by: \.target_user_id)
            .mapValues { Set($0.map(\.target_driver_id)) }

        var assignments: [Assignment] = []
        assignments.reserveCapacity(draft.pick_order.count)
        var unavailable = Set<Int>()

        for (pickIndex, userID) in draft.pick_order.enumerated() {
            let bansForUser = bannedByUser[userID] ?? []
            let candidate = RaceDriverSubstitutionPolicy.candidates(
                for: preferencesByUser[userID] ?? [],
                substitutions: definitions
            ).first {
                !unavailable.contains($0.effectiveDriverID)
                    && !bansForUser.contains($0.originalDriverID)
                    && !bansForUser.contains($0.effectiveDriverID)
            }

            let effectiveDriverID = candidate?.effectiveDriverID
            if let effectiveDriverID {
                unavailable.insert(effectiveDriverID)
            }
            assignments.append(Assignment(
                pickIndex: pickIndex,
                userID: userID,
                effectiveDriverID: effectiveDriverID,
                originalDriverID: candidate.flatMap {
                    $0.originalDriverID == $0.effectiveDriverID ? nil : $0.originalDriverID
                }
            ))
        }

        return assignments
    }

    private static func loadSlots(draftID: Int, sql: any SQLDatabase) async throws -> [SlotRow] {
        try await sql.raw("""
            SELECT pick_index, user_id, driver_id, original_driver_id
            FROM v2_draft_slots
            WHERE draft_id = \(bind: draftID)
            ORDER BY pick_index
        """).all(decoding: SlotRow.self)
    }

    private static func changes(from slots: [SlotRow], to assignments: [Assignment]) -> [PickChange] {
        let slotsByIndex = Dictionary(uniqueKeysWithValues: slots.map { ($0.pick_index, $0) })
        return assignments.compactMap { assignment in
            let previous = slotsByIndex[assignment.pickIndex]
            let previousNormalizedOriginal = previous.flatMap { $0.original_driver_id ?? $0.driver_id }
            let nextNormalizedOriginal = assignment.originalDriverID ?? assignment.effectiveDriverID
            guard previous?.driver_id != assignment.effectiveDriverID
                    || previousNormalizedOriginal != nextNormalizedOriginal else {
                return nil
            }
            return PickChange(
                pickIndex: assignment.pickIndex,
                userID: assignment.userID,
                previousDriverID: previous?.driver_id,
                previousOriginalDriverID: previous?.original_driver_id,
                effectiveDriverID: assignment.effectiveDriverID,
                originalDriverID: assignment.originalDriverID
            )
        }
    }

    private static func replaceSlots(
        draft: DraftRow,
        assignments: [Assignment],
        revision: Int,
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("DELETE FROM v2_draft_slots WHERE draft_id = \(bind: draft.id)").run()

        var seenUsers = Set<Int>()
        for assignment in assignments {
            let isMirrorPick = draft.mirror_picks && seenUsers.contains(assignment.userID)
            try await sql.raw("""
                INSERT INTO v2_draft_slots (
                    draft_id, pick_index, user_id, driver_id, original_driver_id,
                    is_mirror_pick, resolution_revision, substitution_revision, updated_at
                ) VALUES (
                    \(bind: draft.id), \(bind: assignment.pickIndex), \(bind: assignment.userID),
                    \(bind: assignment.effectiveDriverID), \(bind: assignment.originalDriverID),
                    \(bind: isMirrorPick), \(bind: revision), \(bind: revision), NOW()
                )
            """).run()
            seenUsers.insert(assignment.userID)
        }

        try await sql.raw("""
            UPDATE race_drafts
            SET resolution_revision = \(bind: revision), updated_at = NOW()
            WHERE id = \(bind: draft.id)
        """).run()

        if draft.resolution_state == V2DraftResolutionState.finalized.rawValue {
            try await sql.raw("""
                DELETE FROM player_picks
                WHERE draft_id = \(bind: draft.id)
                  AND is_banned = false
            """).run()
            try await sql.raw("""
                INSERT INTO player_picks (
                    draft_id, user_id, driver_id, original_driver_id, substitution_revision,
                    is_banned, is_mirror_pick, is_autopick, picked_at
                )
                SELECT draft_id, user_id, driver_id, original_driver_id, substitution_revision,
                       false, is_mirror_pick, false, NOW()
                FROM v2_draft_slots
                WHERE draft_id = \(bind: draft.id)
                  AND driver_id IS NOT NULL
                ORDER BY pick_index
            """).run()
        }
    }

    private static func replaceConfiguration(
        raceID: Int,
        definitions: [RaceDriverSubstitutionPolicy.Definition],
        roster: [RosterEntry],
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("DELETE FROM race_driver_substitutions WHERE race_id = \(bind: raceID)").run()
        for definition in definitions {
            try await sql.raw("""
                INSERT INTO race_driver_substitutions (
                    race_id, outgoing_driver_id, incoming_driver_id, f1_team_id, announced_at
                ) VALUES (
                    \(bind: raceID), \(bind: definition.outgoingDriverID),
                    \(bind: definition.incomingDriverID), \(bind: definition.f1TeamID),
                    \(bind: definition.announcedAt)
                )
            """).run()
        }

        try await sql.raw("DELETE FROM race_driver_entries WHERE race_id = \(bind: raceID)").run()
        for entry in roster {
            try await sql.raw("""
                INSERT INTO race_driver_entries (race_id, driver_id, f1_team_id, status)
                VALUES (
                    \(bind: raceID), \(bind: entry.driverID),
                    \(bind: entry.f1TeamID), \(bind: entry.status)
                )
            """).run()
        }
    }
}
