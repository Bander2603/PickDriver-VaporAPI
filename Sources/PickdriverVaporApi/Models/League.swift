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

    @Field(key: "invite_code")
    var code: String

    @Field(key: "status")
    var status: String

    @Field(key: "initial_race_round")
    var initialRaceRound: Int?

    @Parent(key: "owner_id")
    var creator: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Field(key: "teams_enabled")
    var teamsEnabled: Bool

    @Field(key: "bans_enabled")
    var bansEnabled: Bool

    @Field(key: "mirror_picks_enabled")
    var mirrorEnabled: Bool
    
    @Field(key: "max_players")
    var maxPlayers: Int
    
    @Field(key: "season_id")
    var seasonID: Int

    init() {}

    init(id: Int? = nil, name: String, code: String, status: String, initialRaceRound: Int? = nil, creatorID: Int,
         teamsEnabled: Bool = false, bansEnabled: Bool = false, mirrorEnabled: Bool = false, maxPlayers: Int, seasonID: Int) {
        self.id = id
        self.name = name
        self.code = code
        self.status = status
        self.initialRaceRound = initialRaceRound
        self.$creator.id = creatorID
        self.teamsEnabled = teamsEnabled
        self.bansEnabled = bansEnabled
        self.mirrorEnabled = mirrorEnabled
        self.maxPlayers = maxPlayers
        self.seasonID = seasonID
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

    @OptionalField(key: "pick_order")
    var pickOrder: Int?

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() {}

    init(userID: Int, leagueID: Int, pickOrder: Int? = nil) {
        self.$user.id = userID
        self.$league.id = leagueID
        self.pickOrder = pickOrder
    }
}

final class LeagueTeam: Model, Content, @unchecked Sendable {
    static let schema = "league_teams"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "name")
    var name: String

    @Parent(key: "league_id")
    var league: League

    @Children(for: \.$team)
    var members: [TeamMember]

    init() {}
    init(id: Int? = nil, name: String, leagueID: Int) {
        self.id = id
        self.name = name
        self.$league.id = leagueID
    }
}

final class TeamMember: Model, Content, @unchecked Sendable {
    static let schema = "team_members"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "team_id")
    var team: LeagueTeam

    init() {}
    init(userID: Int, teamID: Int) {
        self.$user.id = userID
        self.$team.id = teamID
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
        let maxPlayers: Int
        let teamsEnabled: Bool
        let bansEnabled: Bool
        let mirrorEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case code = "invite_code"
            case status
            case initialRaceRound = "initial_race_round"
            case creatorID = "owner_id"
            case maxPlayers = "max_players"
            case teamsEnabled = "teams_enabled"
            case bansEnabled = "bans_enabled"
            case mirrorEnabled = "mirror_picks_enabled"
        }
    }

    func convertToPublic() -> Public {
        Public(
            id: id,
            name: name,
            code: code,
            status: status,
            initialRaceRound: initialRaceRound,
            creatorID: $creator.id,
            maxPlayers: maxPlayers,
            teamsEnabled: teamsEnabled,
            bansEnabled: bansEnabled,
            mirrorEnabled: mirrorEnabled
        )
    }
}
