//
//  DraftPick.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 24.06.25.
//

import Vapor
import Fluent

final class DraftPick: Model, Content, @unchecked Sendable {
    static let schema = "draft_picks"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "race_draft_id")
    var draft: RaceDraft

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "driver_id")
    var driver: Driver

    @Field(key: "timestamp")
    var timestamp: Date

    init() {}

    init(draftID: Int, userID: Int, driverID: Int) {
        self.$draft.id = draftID
        self.$user.id = userID
        self.$driver.id = driverID
        self.timestamp = Date()
    }
}

final class DraftBan: Model, Content, @unchecked Sendable {
    static let schema = "draft_bans"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "race_draft_id")
    var draft: RaceDraft

    @Parent(key: "user_id")
    var user: User // Who issued the ban

    @Parent(key: "target_user_id")
    var targetUser: User // Who got banned

    @Parent(key: "driver_id")
    var driver: Driver

    @Field(key: "timestamp")
    var timestamp: Date

    init() {}

    init(draftID: Int, userID: Int, targetUserID: Int, driverID: Int) {
        self.$draft.id = draftID
        self.$user.id = userID
        self.$targetUser.id = targetUserID
        self.$driver.id = driverID
        self.timestamp = Date()
    }
}
