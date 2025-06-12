//
//  UpdatePasswordRequest.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 12.06.25.
//

import Foundation
import Vapor
import Fluent

struct UpdatePasswordRequest: Content {
    let currentPassword: String
    let newPassword: String
}
