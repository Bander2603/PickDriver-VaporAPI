//
//  UpdateUsernameRequest.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 30.01.26.
//

import Foundation
import Vapor
import Fluent

struct UpdateUsernameRequest: Content {
    let username: String
}
