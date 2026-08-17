import Fluent
import Vapor

enum DraftGameplayVersion: String, Codable, Sendable {
    case legacy
    case v2
}

enum V2DraftResolutionState: String, Codable, Sendable {
    case legacy
    case collecting
    case resolved
    case finalized
    case cancelled
}

enum PickDriverV2Policy {
    static let cutoverSeasonID = 2
    static let cutoverRound = 14
    static let cutoverRaceID = 39

    static func gameplayVersion(seasonID: Int, round: Int) -> DraftGameplayVersion {
        if seasonID > cutoverSeasonID || (seasonID == cutoverSeasonID && round >= cutoverRound) {
            return .v2
        }
        return .legacy
    }
}

final class PlayerPickPreference: Model, Content, @unchecked Sendable {
    static let schema = "player_pick_preferences"

    @ID(custom: "id") var id: Int?
    @Parent(key: "league_id") var league: League
    @Parent(key: "user_id") var user: User
    @Field(key: "driver_order") var driverOrder: [Int]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(leagueID: Int, userID: Int, driverOrder: [Int]) {
        self.$league.id = leagueID
        self.$user.id = userID
        self.driverOrder = driverOrder
    }
}
