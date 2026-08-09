import Fluent
import Vapor

final class LeaguePlayoff: Model, Content, @unchecked Sendable {
    static let schema = "league_playoffs"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "league_id")
    var league: League

    @Field(key: "regular_race_count")
    var regularRaceCount: Int

    @Field(key: "first_race_id")
    var firstRaceID: Int

    @Field(key: "playoff_race_ids")
    var playoffRaceIDs: [Int]

    @Field(key: "selection_deadline")
    var selectionDeadline: Date

    @Field(key: "seed_order")
    var seedOrder: [Int]

    @Field(key: "top_group_size")
    var topGroupSize: Int

    @Field(key: "first_pick_order")
    var firstPickOrder: [Int]

    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}
}

final class LeaguePlayoffPickSelection: Model, Content, @unchecked Sendable {
    static let schema = "league_playoff_pick_selections"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "playoff_id")
    var playoff: LeaguePlayoff

    @Parent(key: "user_id")
    var user: User

    @Field(key: "selection_rank")
    var selectionRank: Int

    @OptionalField(key: "pick_position")
    var pickPosition: Int?

    @OptionalField(key: "selected_at")
    var selectedAt: Date?

    init() {}
}
