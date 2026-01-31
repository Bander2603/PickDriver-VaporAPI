//
//  F1Team.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 31.01.26.
//

import Vapor
import Fluent

final class F1Team: Model, Content, @unchecked Sendable {
    static let schema = "f1_teams"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "season_id")
    var seasonID: Int

    @Field(key: "name")
    var name: String

    @Field(key: "color")
    var color: String

    init() {}

    init(id: Int? = nil, seasonID: Int, name: String, color: String) {
        self.id = id
        self.seasonID = seasonID
        self.name = name
        self.color = color
    }
}
