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

    init() {}

    init(leagueID: Int, raceID: Int, pickOrder: [Int], mirrorPicks: Bool, status: String) {
        self.$league.id = leagueID
        self.raceID = raceID
        self.pickOrder = pickOrder
        self.currentPickIndex = 0
        self.mirrorPicks = mirrorPicks
        self.status = status
    }
}
