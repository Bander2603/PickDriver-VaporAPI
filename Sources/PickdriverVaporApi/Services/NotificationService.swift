//
//  NotificationService.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Fluent
import SQLKit
import Vapor

enum NotificationService {
    private struct RecipientRow: Decodable {
        let user_id: Int
        let league_id: Int
        let league_name: String
    }

    private struct ExistingRow: Decodable {
        let user_id: Int
        let league_id: Int
    }

    private struct RecipientKey: Hashable {
        let userID: Int
        let leagueID: Int
    }

    private static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This operation requires an SQLDatabase (Postgres).")
        }
        return sql
    }

    private static func deliverIfPossible(
        _ notification: PushNotification,
        on db: any Database,
        app: Application
    ) async {
        guard app.apnsService.isEnabled else { return }

        let recipientID = notification.$user.id

        do {
            let activeTokens = try await PushToken.query(on: db)
                .filter(\.$user.$id == recipientID)
                .filter(\.$isActive == true)
                .all()

            guard !activeTokens.isEmpty else { return }

            var delivered = false
            for token in activeTokens {
                do {
                    let result = try await app.apnsService.sendAlert(
                        title: notification.title,
                        body: notification.body,
                        data: notification.data,
                        to: token.token,
                        on: app
                    )

                    switch result {
                    case .delivered:
                        delivered = true
                        token.lastSeenAt = Date()
                        try await token.save(on: db)

                    case let .invalidDeviceToken(reason):
                        token.isActive = false
                        token.lastSeenAt = Date()
                        try await token.save(on: db)
                        app.logger.warning("APNS invalid token deactivated for user \(recipientID). Reason: \(reason)")

                    case let .rejected(status, reason):
                        let normalized = reason ?? "n/a"
                        app.logger.warning("APNS rejected delivery for user \(recipientID). Status: \(status.code). Reason: \(normalized)")
                    }
                } catch {
                    app.logger.warning("APNS delivery error for user \(recipientID): \(error.localizedDescription)")
                }
            }

            if delivered {
                notification.deliveredAt = Date()
                try await notification.save(on: db)
            }
        } catch {
            app.logger.warning("APNS delivery pipeline failed for user \(recipientID): \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func notifyDraftTurn(
        on db: any Database,
        app: Application,
        recipientID: Int,
        league: League,
        race: Race,
        draftID: Int,
        pickIndex: Int
    ) async throws -> PushNotification {
        let leagueID = try league.requireID()
        let raceID = try race.requireID()

        let payload = NotificationPayload(
            leagueID: leagueID,
            raceID: raceID,
            draftID: draftID,
            pickIndex: pickIndex
        )

        let notification = PushNotification(
            userID: recipientID,
            type: .draftTurn,
            title: "Your turn to pick",
            body: "\(league.name) • \(race.name)",
            data: payload,
            leagueID: leagueID,
            raceID: raceID
        )

        try await notification.save(on: db)
        await deliverIfPossible(notification, on: db, app: app)
        return notification
    }

    @discardableResult
    static func notifyRaceResults(on db: any Database, app: Application, raceID: Int) async throws -> Int {
        let sql = try sql(db)

        guard let race = try await Race.find(raceID, on: db) else {
            throw Abort(.notFound, reason: "Race not found.")
        }

        let recipients = try await sql.raw("""
            SELECT DISTINCT lm.user_id, l.id AS league_id, l.name AS league_name
            FROM race_drafts rd
            JOIN leagues l ON l.id = rd.league_id
            JOIN league_members lm ON lm.league_id = l.id
            WHERE rd.race_id = \(bind: raceID)
        """).all(decoding: RecipientRow.self)

        guard !recipients.isEmpty else { return 0 }

        let existingRows = try await sql.raw("""
            SELECT user_id, league_id
            FROM push_notifications
            WHERE type = \(bind: PushNotificationType.raceResults.rawValue)
              AND race_id = \(bind: raceID)
        """).all(decoding: ExistingRow.self)

        let existing = Set(existingRows.map { RecipientKey(userID: $0.user_id, leagueID: $0.league_id) })

        var created = 0
        for recipient in recipients {
            let key = RecipientKey(userID: recipient.user_id, leagueID: recipient.league_id)
            if existing.contains(key) { continue }

            let payload = NotificationPayload(
                leagueID: recipient.league_id,
                raceID: raceID,
                draftID: nil,
                pickIndex: nil
            )

            let notification = PushNotification(
                userID: recipient.user_id,
                type: .raceResults,
                title: "Race results available",
                body: "Results for \(race.name) are now available in \(recipient.league_name).",
                data: payload,
                leagueID: recipient.league_id,
                raceID: raceID
            )

            try await notification.save(on: db)
            await deliverIfPossible(notification, on: db, app: app)
            created += 1
        }

        return created
    }
}
