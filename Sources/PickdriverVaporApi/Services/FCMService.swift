//
//  FCMService.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.03.26.
//

import Foundation
import JWT
import Vapor

struct FCMConfiguration {
    let projectID: String
    let clientEmail: String
    let privateKeyPEM: String
    let tokenURI: String
}

enum FCMDeliveryResult {
    case delivered(messageID: String?)
    case invalidDeviceToken(reason: String)
    case rejected(status: HTTPStatus, reason: String?)
}

protocol FCMService: Sendable {
    var isEnabled: Bool { get }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> FCMDeliveryResult
}

struct DisabledFCMService: FCMService {
    var isEnabled: Bool { false }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> FCMDeliveryResult {
        .rejected(status: .serviceUnavailable, reason: "FCM is disabled.")
    }
}

struct LiveFCMService: FCMService, @unchecked Sendable {
    private static let messagingScope = "https://www.googleapis.com/auth/firebase.messaging"
    private static let invalidTokenCodes: Set<String> = [
        "UNREGISTERED"
    ]

    private let config: FCMConfiguration
    private let signer: JWTSigner
    private let tokenCache = FCMTokenCache()

    init(config: FCMConfiguration) throws {
        self.config = config
        self.signer = try JWTSigner.rs256(key: .private(pem: config.privateKeyPEM))
    }

    var isEnabled: Bool { true }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> FCMDeliveryResult {
        let accessToken = try await resolveAccessToken(on: app)
        let endpoint = URI(string: "https://fcm.googleapis.com/v1/projects/\(config.projectID)/messages:send")

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(accessToken)")
        headers.add(name: .contentType, value: "application/json")

        let payload = FCMSendRequest(
            message: .init(
                token: deviceToken,
                notification: .init(title: title, body: body),
                data: makeDataDictionary(from: data),
                android: .init(
                    priority: "HIGH",
                    notification: .init(
                        channelID: "pickdriver_push_general",
                        sound: "default"
                    )
                )
            )
        )

        let response = try await app.client.post(endpoint, headers: headers) { req in
            try req.content.encode(payload, as: .json)
        }

        if response.status == .ok {
            let success = decodeSuccess(from: response)
            return .delivered(messageID: success?.name)
        }

        let envelope = decodeErrorEnvelope(from: response)
        let reason = envelope?.error.message ?? responseReasonString(from: response)
        if isInvalidDeviceToken(envelope: envelope, fallbackReason: reason) {
            return .invalidDeviceToken(reason: reason ?? "Invalid FCM device token.")
        }

        return .rejected(status: response.status, reason: reason)
    }

    private func resolveAccessToken(on app: Application) async throws -> String {
        if let cached = await tokenCache.validToken() {
            return cached
        }

        let assertion = try makeServiceAccountAssertion()
        let endpoint = URI(string: config.tokenURI)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")

        let encodedAssertion = assertion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? assertion
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(encodedAssertion)"

        let response = try await app.client.post(endpoint, headers: headers) { req in
            req.body = .init(string: body)
        }

        guard response.status == .ok else {
            let reason = responseReasonString(from: response) ?? "HTTP \(response.status.code)"
            throw Abort(.serviceUnavailable, reason: "FCM OAuth token request failed: \(reason)")
        }

        guard let oauth = decodeOAuthResponse(from: response) else {
            throw Abort(.serviceUnavailable, reason: "FCM OAuth token response could not be decoded.")
        }

        await tokenCache.store(token: oauth.accessToken, expiresIn: oauth.expiresIn)
        return oauth.accessToken
    }

    private func makeServiceAccountAssertion() throws -> String {
        let now = Date()
        let claims = FCMServiceAccountClaims(
            issuer: config.clientEmail,
            subject: config.clientEmail,
            audience: config.tokenURI,
            scope: Self.messagingScope,
            issuedAt: .init(value: now),
            expiration: .init(value: now.addingTimeInterval(3600))
        )
        return try signer.sign(claims)
    }

    private func makeDataDictionary(from payload: NotificationPayload?) -> [String: String]? {
        guard let payload else { return nil }
        var data: [String: String] = [:]

        if let leagueID = payload.leagueID {
            data["leagueID"] = String(leagueID)
        }
        if let raceID = payload.raceID {
            data["raceID"] = String(raceID)
        }
        if let draftID = payload.draftID {
            data["draftID"] = String(draftID)
        }
        if let pickIndex = payload.pickIndex {
            data["pickIndex"] = String(pickIndex)
        }

        return data.isEmpty ? nil : data
    }

    private func decodeSuccess(from response: ClientResponse) -> FCMSendSuccessResponse? {
        guard let data = responseBodyData(from: response) else { return nil }
        return try? JSONDecoder().decode(FCMSendSuccessResponse.self, from: data)
    }

    private func decodeOAuthResponse(from response: ClientResponse) -> FCMOAuthTokenResponse? {
        guard let data = responseBodyData(from: response) else { return nil }
        return try? JSONDecoder().decode(FCMOAuthTokenResponse.self, from: data)
    }

    private func decodeErrorEnvelope(from response: ClientResponse) -> FCMErrorEnvelope? {
        guard let data = responseBodyData(from: response) else { return nil }
        return try? JSONDecoder().decode(FCMErrorEnvelope.self, from: data)
    }

    private func responseReasonString(from response: ClientResponse) -> String? {
        guard var body = response.body else { return nil }
        guard let raw = body.readString(length: body.readableBytes) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func responseBodyData(from response: ClientResponse) -> Data? {
        guard var body = response.body else { return nil }
        guard let raw = body.readString(length: body.readableBytes) else { return nil }
        return raw.data(using: .utf8)
    }

    private func isInvalidDeviceToken(
        envelope: FCMErrorEnvelope?,
        fallbackReason: String?
    ) -> Bool {
        let details = envelope?.error.details ?? []
        if details.contains(where: { Self.invalidTokenCodes.contains($0.errorCode ?? "") }) {
            return true
        }

        let status = envelope?.error.status?.uppercased()
        if status == "NOT_FOUND", details.isEmpty {
            return true
        }

        let reason = fallbackReason?.uppercased() ?? ""
        if reason.contains("UNREGISTERED")
            || reason.contains("REGISTRATION TOKEN")
            || reason.contains("REQUESTED ENTITY WAS NOT FOUND") {
            return true
        }

        return false
    }
}

private actor FCMTokenCache {
    private var token: String?
    private var expiresAt: Date?

    func validToken(now: Date = Date()) -> String? {
        guard let token, let expiresAt else { return nil }
        guard expiresAt.timeIntervalSince(now) > 30 else { return nil }
        return token
    }

    func store(token: String, expiresIn: Int, now: Date = Date()) {
        self.token = token
        self.expiresAt = now.addingTimeInterval(Double(max(0, expiresIn - 30)))
    }
}

private struct FCMServiceAccountClaims: JWTPayload {
    let issuer: String
    let subject: String
    let audience: String
    let scope: String
    let issuedAt: IssuedAtClaim
    let expiration: ExpirationClaim

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case audience = "aud"
        case scope
        case issuedAt = "iat"
        case expiration = "exp"
    }

    func verify(using signer: JWTSigner) throws {
        try expiration.verifyNotExpired()
    }
}

private struct FCMOAuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

private struct FCMSendRequest: Encodable {
    let message: Message

    struct Message: Encodable {
        let token: String
        let notification: Notification
        let data: [String: String]?
        let android: AndroidConfig?

        struct Notification: Encodable {
            let title: String
            let body: String
        }

        struct AndroidConfig: Encodable {
            let priority: String
            let notification: AndroidNotification?

            struct AndroidNotification: Encodable {
                let channelID: String?
                let sound: String?

                enum CodingKeys: String, CodingKey {
                    case channelID = "channel_id"
                    case sound
                }
            }
        }
    }
}

private struct FCMSendSuccessResponse: Decodable {
    let name: String?
}

private struct FCMErrorEnvelope: Decodable {
    let error: FCMError

    struct FCMError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
        let details: [FCMErrorDetail]?
    }

    struct FCMErrorDetail: Decodable {
        let type: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case errorCode
        }
    }
}

extension Application {
    private struct FCMServiceKey: StorageKey {
        typealias Value = any FCMService
    }

    var fcmService: any FCMService {
        get { self.storage[FCMServiceKey.self] ?? DisabledFCMService() }
        set { self.storage[FCMServiceKey.self] = newValue }
    }
}
