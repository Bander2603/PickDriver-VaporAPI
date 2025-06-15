//
//  TeamStanding.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

struct TeamStanding: Content {
    let team_id: Int
    let name: String
    let color: String
    let points: Int
}
