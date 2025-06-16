//
//  League.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

final class League: Model, Content, @unchecked Sendable {
    static let schema = "leagues"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "name")
    var name: String

    @Field(key: "code")
    var code: String

    @Field(key: "status")
    var status: String

    @Field(key: "initial_race_round")
    var initialRaceRound: Int?

    @Parent(key: "creator_id")
    var creator: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: Int? = nil, name: String, code: String, status: String, initialRaceRound: Int? = nil, creatorID: Int) {
        self.id = id
        self.name = name
        self.code = code
        self.status = status
        self.initialRaceRound = initialRaceRound
        self.$creator.id = creatorID
    }
}

final class LeagueMember: Model, Content, @unchecked Sendable {
    static let schema = "league_members"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "league_id")
    var league: League

    @Field(key: "pick_order")
    var pickOrder: Int?

    init() {}

    init(id: Int? = nil, userID: Int, leagueID: Int, pickOrder: Int? = nil) {
        self.id = id
        self.$user.id = userID
        self.$league.id = leagueID
        self.pickOrder = pickOrder
    }
}


extension League {
    struct Public: Content {
        let id: Int?
        let name: String
        let code: String
        let status: String
        let initialRaceRound: Int?
        let creatorID: Int
    }

    func convertToPublic() -> Public {
        Public(id: id,
               name: name,
               code: code,
               status: status,
               initialRaceRound: initialRaceRound,
               creatorID: $creator.id)
    }
}
