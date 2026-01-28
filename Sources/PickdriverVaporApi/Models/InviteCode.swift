//
//  InviteCode.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 29.01.26.
//

import Foundation
import Vapor
import Fluent

final class InviteCode: Model, @unchecked Sendable {
    static let schema = "invite_codes"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "code")
    var code: String

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @OptionalParent(key: "used_by_user_id")
    var usedByUser: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: Int? = nil, code: String) {
        self.id = id
        self.code = code
    }
}
