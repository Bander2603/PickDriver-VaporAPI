//
//  DriverStanding.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 15.06.25.
//

import Vapor
import Fluent

struct DriverStanding: Content {
    let driver_id: Int
    let first_name: String
    let last_name: String
    let driver_code: String
    let points: Int
    let team_id: Int
    let team_name: String
    let team_color: String
}

