//
//  NotificationController.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Vapor
import Fluent

struct NotificationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(UserAuthenticator())
        let notifications = protected.grouped("notifications")

        notifications.get(use: listNotifications)
        notifications.post("devices", use: registerDevice)
        notifications.delete("devices", use: unregisterDevice)
        notifications.post(":notificationID", "read", use: markAsRead)
    }

    struct DeviceRegistrationRequest: Content {
        let token: String
        let platform: String
        let deviceID: String?
    }

    struct DeviceUnregisterRequest: Content {
        let token: String
    }

    func registerDevice(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let data = try req.content.decode(DeviceRegistrationRequest.self)

        let trimmedToken = data.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid device token.")
        }

        if let existing = try await PushToken.query(on: req.db)
            .filter(\.$token == trimmedToken)
            .first() {
            existing.$user.id = userID
            existing.platform = data.platform
            existing.deviceID = data.deviceID
            existing.isActive = true
            existing.lastSeenAt = Date()
            try await existing.save(on: req.db)
        } else {
            let token = PushToken(
                userID: userID,
                token: trimmedToken,
                platform: data.platform,
                deviceID: data.deviceID,
                isActive: true
            )
            token.lastSeenAt = Date()
            try await token.save(on: req.db)
        }

        return .ok
    }

    func unregisterDevice(_ req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let data = try req.content.decode(DeviceUnregisterRequest.self)

        guard let token = try await PushToken.query(on: req.db)
            .filter(\.$token == data.token)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound, reason: "Device token not found.")
        }

        token.isActive = false
        token.lastSeenAt = Date()
        try await token.save(on: req.db)

        return .ok
    }

    func listNotifications(_ req: Request) async throws -> [PushNotification.Public] {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let requestedLimit = req.query["limit"] ?? 50
        let limit = min(max(requestedLimit, 0), 100)
        let unreadOnly = req.query["unread_only"] ?? false

        var query = PushNotification.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)

        if unreadOnly {
            query = query.filter(\.$readAt == nil)
        }

        let notifications = try await query.range(0..<limit).all()
        return notifications.map { $0.asPublic() }
    }

    func markAsRead(_ req: Request) async throws -> PushNotification.Public {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let notificationID = req.parameters.get("notificationID", as: Int.self) else {
            throw Abort(.badRequest, reason: "Invalid notification ID.")
        }

        guard let notification = try await PushNotification.find(notificationID, on: req.db) else {
            throw Abort(.notFound, reason: "Notification not found.")
        }

        guard notification.$user.id == userID else {
            throw Abort(.forbidden, reason: "Not allowed to read this notification.")
        }

        notification.readAt = Date()
        try await notification.save(on: req.db)

        return notification.asPublic()
    }
}
