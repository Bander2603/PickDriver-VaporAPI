//
//  RaceDraft.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 22.06.25.
//

import Vapor
import Fluent

final class RaceDraft: Model, Content, @unchecked Sendable {
    static let schema = "race_drafts"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "league_id")
    var league: League

    @Field(key: "race_id")
    var raceID: Int

    @Field(key: "pick_order")
    var pickOrder: [Int] // list of user_ids or team_ids depending on config

    @Field(key: "current_pick_index")
    var currentPickIndex: Int

    @Field(key: "mirror_picks")
    var mirrorPicks: Bool

    @Field(key: "status")
    var status: String  

    @OptionalField(key: "protected_repick_user_id")
    var protectedRepickUserID: Int?

    @OptionalField(key: "protected_repick_pick_index")
    var protectedRepickPickIndex: Int?

    @OptionalField(key: "protected_repick_deadline")
    var protectedRepickDeadline: Date?

    init() {}

    init(leagueID: Int, raceID: Int, pickOrder: [Int], mirrorPicks: Bool, status: String) {
        self.$league.id = leagueID
        self.raceID = raceID
        self.pickOrder = pickOrder
        self.currentPickIndex = 0
        self.mirrorPicks = mirrorPicks
        self.status = status
        self.protectedRepickUserID = nil
        self.protectedRepickPickIndex = nil
        self.protectedRepickDeadline = nil
    }
}

struct ProtectedRepickState {
    let userID: Int
    let pickIndex: Int
    let deadline: Date
}

struct DraftDeadline: Content {
    let raceID: Int
    let leagueID: Int
    let firstHalfDeadline: Date
    let secondHalfDeadline: Date
    let protectedRepickUserID: Int?
    let protectedRepickPickIndex: Int?
    let protectedRepickDeadline: Date?

    init(
        raceID: Int,
        leagueID: Int,
        firstHalfDeadline: Date,
        secondHalfDeadline: Date,
        protectedRepickUserID: Int? = nil,
        protectedRepickPickIndex: Int? = nil,
        protectedRepickDeadline: Date? = nil
    ) {
        self.raceID = raceID
        self.leagueID = leagueID
        self.firstHalfDeadline = firstHalfDeadline
        self.secondHalfDeadline = secondHalfDeadline
        self.protectedRepickUserID = protectedRepickUserID
        self.protectedRepickPickIndex = protectedRepickPickIndex
        self.protectedRepickDeadline = protectedRepickDeadline
    }
}

func effectiveDeadlineForPickIndex(
    pickIndex: Int,
    totalPickCount: Int,
    deadlines: DraftDeadline,
    protectedRepick: ProtectedRepickState?
) -> Date {
    let firstHalfCount = (totalPickCount + 1) / 2
    let baseDeadline = pickIndex < firstHalfCount ? deadlines.firstHalfDeadline : deadlines.secondHalfDeadline

    guard let protectedRepick, protectedRepick.pickIndex == pickIndex else {
        return baseDeadline
    }

    return max(baseDeadline, protectedRepick.deadline)
}
