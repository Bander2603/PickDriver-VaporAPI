//
//  PushNotification.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Vapor
import Fluent

enum PushNotificationType: String, Codable {
    case draftTurn = "draft_turn"
    case raceResults = "race_results"
}

struct NotificationPayload: Codable, Content {
    var leagueID: Int?
    var raceID: Int?
    var draftID: Int?
    var pickIndex: Int?
}

final class PushNotification: Model, Content, @unchecked Sendable {
    static let schema = "push_notifications"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "type")
    var type: String

    @Field(key: "title")
    var title: String

    @Field(key: "body")
    var body: String

    @OptionalField(key: "data")
    var data: NotificationPayload?

    @OptionalField(key: "league_id")
    var leagueID: Int?

    @OptionalField(key: "race_id")
    var raceID: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "read_at")
    var readAt: Date?

    @OptionalField(key: "delivered_at")
    var deliveredAt: Date?

    init() {}

    init(
        userID: Int,
        type: PushNotificationType,
        title: String,
        body: String,
        data: NotificationPayload? = nil,
        leagueID: Int? = nil,
        raceID: Int? = nil
    ) {
        self.$user.id = userID
        self.type = type.rawValue
        self.title = title
        self.body = body
        self.data = data
        self.leagueID = leagueID
        self.raceID = raceID
    }
}

extension PushNotification {
    struct Public: Content {
        let id: Int?
        let type: String
        let title: String
        let body: String
        let data: NotificationPayload?
        let leagueID: Int?
        let raceID: Int?
        let createdAt: Date?
        let readAt: Date?
        let deliveredAt: Date?
    }

    func asPublic() -> Public {
        Public(
            id: id,
            type: type,
            title: title,
            body: body,
            data: data,
            leagueID: leagueID,
            raceID: raceID,
            createdAt: createdAt,
            readAt: readAt,
            deliveredAt: deliveredAt
        )
    }
}
