//
//  Driver.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

final class Driver: Model, Content, @unchecked Sendable {
    static let schema = "drivers"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "season_id")
    var seasonID: Int

    @Field(key: "f1_team_id")
    var teamID: Int

    @Field(key: "first_name")
    var firstName: String

    @Field(key: "last_name")
    var lastName: String

    @Field(key: "country")
    var country: String

    @Field(key: "driver_number")
    var driverNumber: Int

    @Field(key: "active")
    var active: Bool

    @Field(key: "driver_code")
    var driverCode: String

    init() {}

    init(id: Int? = nil, seasonID: Int, teamID: Int, firstName: String, lastName: String, country: String, driverNumber: Int, active: Bool, driverCode: String) {
        self.id = id
        self.seasonID = seasonID
        self.teamID = teamID
        self.firstName = firstName
        self.lastName = lastName
        self.country = country
        self.driverNumber = driverNumber
        self.active = active
        self.driverCode = driverCode
    }
}
