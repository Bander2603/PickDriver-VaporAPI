import Vapor

enum RaceDriverSubstitutionPolicy {
    struct Definition: Content, Hashable, Sendable {
        let outgoingDriverID: Int
        let incomingDriverID: Int
        let f1TeamID: Int
        let announcedAt: Date?
    }

    struct Candidate: Equatable, Sendable {
        let originalDriverID: Int
        let effectiveDriverID: Int
    }

    /// Applies one race-scoped substitution step to each preference. A driver who is
    /// both an incoming and outgoing driver (Lawson in Hadjar -> Lawson -> Tsunoda)
    /// moves to the next replacement only when its predecessor appeared earlier in
    /// that player's frozen list.
    static func candidates(
        for driverOrder: [Int],
        substitutions: [Definition]
    ) -> [Candidate] {
        let byOutgoing = Dictionary(uniqueKeysWithValues: substitutions.map {
            ($0.outgoingDriverID, $0.incomingDriverID)
        })
        let predecessorsByIncoming = Dictionary(grouping: substitutions, by: \.incomingDriverID)
            .mapValues { Set($0.map(\.outgoingDriverID)) }

        var seenOriginalDrivers = Set<Int>()
        var seenEffectiveDrivers = Set<Int>()
        var result: [Candidate] = []
        result.reserveCapacity(driverOrder.count)

        for originalDriverID in driverOrder {
            let effectiveDriverID: Int
            if let incomingDriverID = byOutgoing[originalDriverID] {
                if let predecessors = predecessorsByIncoming[originalDriverID] {
                    effectiveDriverID = !predecessors.isDisjoint(with: seenOriginalDrivers)
                        ? incomingDriverID
                        : originalDriverID
                } else {
                    effectiveDriverID = incomingDriverID
                }
            } else {
                effectiveDriverID = originalDriverID
            }

            seenOriginalDrivers.insert(originalDriverID)
            guard seenEffectiveDrivers.insert(effectiveDriverID).inserted else {
                continue
            }
            result.append(Candidate(
                originalDriverID: originalDriverID,
                effectiveDriverID: effectiveDriverID
            ))
        }

        return result
    }
}
