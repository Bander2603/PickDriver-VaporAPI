//
//  PushToken.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Vapor
import Fluent

final class PushToken: Model, Content, @unchecked Sendable {
    static let schema = "push_tokens"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token")
    var token: String

    @Field(key: "platform")
    var platform: String

    @OptionalField(key: "device_id")
    var deviceID: String?

    @Field(key: "is_active")
    var isActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    init() {}

    init(
        userID: Int,
        token: String,
        platform: String,
        deviceID: String? = nil,
        isActive: Bool = true
    ) {
        self.$user.id = userID
        self.token = token
        self.platform = platform
        self.deviceID = deviceID
        self.isActive = isActive
    }
}
