//
//  Race.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.06.25.
//

import Fluent
import FluentKit
import Vapor

final class Race: Model, Content, @unchecked Sendable {
    static let schema = "races"
    
    struct CircuitData: Codable, Content {
        var laps: Int?
        var first_gp: Int?
        var race_distance: Double?
        var circuit_length: Double?
        var lap_record_time: String?
        var lap_record_driver: String?
    }

    @ID(custom: "id")
    var id: Int?

    @Field(key: "season_id")
    var seasonID: Int

    @Field(key: "round")
    var round: Int

    @Field(key: "name")
    var name: String

    @Field(key: "circuit_name")
    var circuitName: String

    @OptionalField(key: "circuit_data")
    var circuitData: CircuitData?

    @Field(key: "country")
    var country: String

    @Field(key: "country_code")
    var countryCode: String

    @Field(key: "sprint")
    var sprint: Bool

    @Field(key: "completed")
    var completed: Bool

    @OptionalField(key: "fp1_time")
    var fp1Time: Date?

    @OptionalField(key: "fp2_time")
    var fp2Time: Date?

    @OptionalField(key: "fp3_time")
    var fp3Time: Date?

    @OptionalField(key: "qualifying_time")
    var qualifyingTime: Date?

    @OptionalField(key: "sprint_time")
    var sprintTime: Date?

    @OptionalField(key: "race_time")
    var raceTime: Date?

    @OptionalField(key: "sprint_qualifying_time")
    var sprintQualifyingTime: Date?

    init() {}
}

