//
//  MediaAssetService.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 06.03.26.
//

import Foundation
import Vapor

enum MediaAssetService {
    static func raceMedia(for race: Race, req: Request) -> RaceController.RaceMedia {
        let circuitSlug = slugify(race.circuitName)
        let countryCode = race.countryCode.lowercased()

        return .init(
            countryFlagURL: assetURL(relativePath: "media/country-flags/\(countryCode).png", req: req),
            circuitURL: assetURL(relativePath: "media/circuits/\(circuitSlug).png", req: req),
            circuitSimpleURL: assetURL(relativePath: "media/circuits-simple/\(circuitSlug).png", req: req)
        )
    }

    private static func assetURL(relativePath: String, req: Request) -> String {
        let normalizedPath = relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
        guard let configuredBase = req.application.mediaPublicBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return normalizedPath
        }

        let base = configuredBase.hasSuffix("/") ? String(configuredBase.dropLast()) : configuredBase
        return "\(base)\(normalizedPath)"
    }

    private static func slugify(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
