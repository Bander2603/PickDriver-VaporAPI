//
//  PlayerAutopick.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Vapor
import Fluent

final class PlayerAutopick: Model, Content, @unchecked Sendable {
    static let schema = "player_autopicks"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "league_id")
    var league: League

    @Parent(key: "user_id")
    var user: User

    @Field(key: "driver_order")
    var driverOrder: [Int]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(leagueID: Int, userID: Int, driverOrder: [Int]) {
        self.$league.id = leagueID
        self.$user.id = userID
        self.driverOrder = driverOrder
    }
}
