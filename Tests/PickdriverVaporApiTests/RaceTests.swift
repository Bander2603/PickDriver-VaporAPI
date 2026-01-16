//
//  RaceTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
@testable import PickdriverVaporApi

final class RaceTests: XCTestCase {

    func testGetAllRacesSortedByRound() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)

            // Insert out of order
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 2,
                name: "Race 2",
                completed: false,
                raceTime: Date().addingTimeInterval(6000)
            )
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 1,
                name: "Race 1",
                completed: false,
                raceTime: Date().addingTimeInterval(5000)
            )

            try await app.test(.GET, "/api/races", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let races = try res.content.decode([Race].self)
                XCTAssertEqual(races.map { $0.round }, [1, 2])
            })
        }
    }

    func testGetUpcomingRacesOnlyFutureSortedByRaceTime() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)

            // Past race (should not appear)
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 1,
                name: "Past",
                completed: true,
                raceTime: Date().addingTimeInterval(-3600)
            )

            let t1 = Date().addingTimeInterval(7200)
            let t2 = Date().addingTimeInterval(10800)

            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 2,
                name: "Future 2",
                completed: false,
                raceTime: t2
            )
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 3,
                name: "Future 1",
                completed: false,
                raceTime: t1
            )

            try await app.test(.GET, "/api/races/upcoming", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let races = try res.content.decode([Race].self)
                XCTAssertEqual(races.count, 2)
                XCTAssertEqual(races.first?.raceTime, t1)
                XCTAssertEqual(races.last?.raceTime, t2)
            })
        }
    }

    func testGetCurrentReturnsClosestUpcomingNotCompletedRace() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)

            let near = Date().addingTimeInterval(3600)
            let far = Date().addingTimeInterval(7200)

            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 1,
                name: "Far",
                completed: false,
                raceTime: far
            )
            let expected = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 2,
                name: "Near",
                completed: false,
                raceTime: near
            )

            try await app.test(.GET, "/api/races/current", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let race = try res.content.decode(Race.self)
                XCTAssertEqual(race.id, expected.id)
                XCTAssertEqual(race.name, "Near")
            })
        }
    }

    func testGetCurrentReturns404WhenNoUpcomingRace() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)

            // Only past or completed
            _ = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 1,
                name: "Completed Past",
                completed: true,
                raceTime: Date().addingTimeInterval(-3600)
            )

            try await app.test(.GET, "/api/races/current", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("no upcoming"))
            })
        }
    }

    func testGetRaceByID() async throws {
        try await withTestApp { app in
            let season = try await TestSeed.createSeason(app: app)
            let race = try await TestSeed.createRace(
                app: app,
                seasonID: season.id!,
                round: 1,
                name: "Test GP",
                completed: false,
                raceTime: Date().addingTimeInterval(3600)
            )

            try await app.test(.GET, "/api/races/\(race.id!)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let got = try res.content.decode(Race.self)
                XCTAssertEqual(got.id, race.id)
                XCTAssertEqual(got.name, "Test GP")
            })

            try await app.test(.GET, "/api/races/999999", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
                let err = try res.content.decode(APIErrorResponse.self)
                XCTAssertTrue(err.reason.lowercased().contains("race not found"))
            })
        }
    }
}
