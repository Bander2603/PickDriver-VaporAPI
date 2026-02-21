//
//  APNSEnvironment.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 21.02.26.
//

import Foundation
import JWT
import Vapor

enum APNSEnvironment: String {
    case sandbox
    case production

    var host: String {
        switch self {
        case .sandbox:
            return "api.sandbox.push.apple.com"
        case .production:
            return "api.push.apple.com"
        }
    }
}

struct APNSConfiguration {
    let keyID: String
    let teamID: String
    let topic: String
    let environment: APNSEnvironment
    let privateKeyPEM: String
}

enum APNSDeliveryResult {
    case delivered
    case invalidDeviceToken(reason: String)
    case rejected(status: HTTPStatus, reason: String?)
}

protocol APNSService: Sendable {
    var isEnabled: Bool { get }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> APNSDeliveryResult
}

struct DisabledAPNSService: APNSService {
    var isEnabled: Bool { false }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> APNSDeliveryResult {
        .rejected(status: .serviceUnavailable, reason: "APNS is disabled.")
    }
}

struct LiveAPNSService: APNSService, @unchecked Sendable {
    private static let invalidTokenReasons: Set<String> = [
        "BadDeviceToken",
        "Unregistered",
        "DeviceTokenNotForTopic"
    ]

    private let config: APNSConfiguration
    private let signer: JWTSigner
    private let keyIdentifier: JWKIdentifier

    init(config: APNSConfiguration) throws {
        self.config = config
        self.keyIdentifier = .init(string: config.keyID)
        self.signer = try JWTSigner.es256(key: .private(pem: config.privateKeyPEM))
    }

    var isEnabled: Bool { true }

    func sendAlert(
        title: String,
        body: String,
        data: NotificationPayload?,
        to deviceToken: String,
        on app: Application
    ) async throws -> APNSDeliveryResult {
        let token = try makeProviderToken()
        let uri = URI(string: "https://\(config.environment.host)/3/device/\(deviceToken)")

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "bearer \(token)")
        headers.add(name: "apns-topic", value: config.topic)
        headers.add(name: "apns-push-type", value: "alert")
        headers.add(name: "apns-priority", value: "10")

        let payload = APNSAlertPayload(
            aps: .init(
                alert: .init(title: title, body: body),
                sound: "default"
            ),
            data: data
        )

        let response = try await app.client.post(uri, headers: headers) { req in
            try req.content.encode(payload, as: .json)
        }

        if response.status == .ok {
            return .delivered
        }

        let reason = decodeAPNSReason(from: response)
        if let reason, Self.invalidTokenReasons.contains(reason) {
            return .invalidDeviceToken(reason: reason)
        }

        return .rejected(status: response.status, reason: reason)
    }

    private func makeProviderToken() throws -> String {
        let claims = APNSProviderTokenClaims(
            issuer: config.teamID,
            issuedAt: .init(value: Date())
        )
        return try signer.sign(claims, kid: keyIdentifier)
    }

    private func decodeAPNSReason(from response: ClientResponse) -> String? {
        guard var body = response.body else { return nil }
        guard let bodyString = body.readString(length: body.readableBytes) else { return nil }
        guard !bodyString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = bodyString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(APNSErrorEnvelope.self, from: data).reason
    }
}

private struct APNSProviderTokenClaims: JWTPayload {
    let issuer: String
    let issuedAt: IssuedAtClaim

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case issuedAt = "iat"
    }

    func verify(using signer: JWTSigner) throws {}
}

private struct APNSAlertPayload: Encodable {
    struct APS: Encodable {
        struct Alert: Encodable {
            let title: String
            let body: String
        }

        let alert: Alert
        let sound: String
    }

    let aps: APS
    let data: NotificationPayload?
}

private struct APNSErrorEnvelope: Decodable {
    let reason: String
}

extension Application {
    private struct APNSServiceKey: StorageKey {
        typealias Value = any APNSService
    }

    var apnsService: any APNSService {
        get { self.storage[APNSServiceKey.self] ?? DisabledAPNSService() }
        set { self.storage[APNSServiceKey.self] = newValue }
    }
}
