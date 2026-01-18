//
//  DraftPick.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 24.06.25.
//

import Vapor
import Fluent

final class DraftPick: Model, Content, @unchecked Sendable {
    static let schema = "player_picks"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "draft_id")
    var draft: RaceDraft

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "driver_id")
    var driver: Driver

    @Field(key: "is_mirror_pick")
    var isMirrorPick: Bool

    @Timestamp(key: "picked_at", on: .create)
    var pickedAt: Date?

    @Field(key: "is_banned")
    var isBanned: Bool

    @OptionalParent(key: "banned_by")
    var bannedBy: User?

    @OptionalField(key: "banned_at")
    var bannedAt: Date?

    init() {}

    init(draftID: Int, userID: Int, driverID: Int, isMirrorPick: Bool = false) {
        self.$draft.id = draftID
        self.$user.id = userID
        self.$driver.id = driverID
        self.isMirrorPick = isMirrorPick
        self.isBanned = false
    }
}
