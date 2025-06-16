//
//  Season.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 17.06.25.
//

import Vapor
import Fluent

final class Season: Model, Content, @unchecked Sendable {
    static let schema = "seasons"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "year")
    var year: Int

    @Field(key: "name")
    var name: String

    @Field(key: "active")
    var active: Bool

    init() {}

    init(id: Int? = nil, year: Int, name: String, active: Bool) {
        self.id = id
        self.year = year
        self.name = name
        self.active = active
    }
}
