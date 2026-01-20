//
//  User.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.06.25.
//

import Foundation
import Vapor
import Fluent

final class User: Model, @unchecked Sendable, Authenticatable {
    static let schema = "users"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "username")
    var username: String

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @Field(key: "email_verified")
    var emailVerified: Bool

    @OptionalField(key: "email_verification_token_hash")
    var emailVerificationTokenHash: String?

    @OptionalField(key: "email_verification_expires_at")
    var emailVerificationExpiresAt: Date?

    @OptionalField(key: "email_verification_sent_at")
    var emailVerificationSentAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: Int? = nil,
        username: String,
        email: String,
        passwordHash: String,
        emailVerified: Bool = false
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.passwordHash = passwordHash
        self.emailVerified = emailVerified
    }
}

extension User {
    struct Public: Content {
        let id: Int?
        let username: String
        let email: String
        let emailVerified: Bool
    }

    func convertToPublic() -> Public {
        Public(id: id, username: username, email: email, emailVerified: emailVerified)
    }
}

