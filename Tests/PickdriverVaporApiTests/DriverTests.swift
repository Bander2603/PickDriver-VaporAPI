//
//  DriverTests.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 16.01.26.
//

import XCTVapor
@testable import PickdriverVaporApi

final class DriverTests: XCTestCase {
    func testGetAllDrivers() async throws {
        let app = try await TestApp.make()
        defer { Task { await TestApp.shutdown(app) } }

        let season = try await TestSeed.createSeason(app: app)
        let team = try await TestSeed.createF1Team(app: app, seasonID: season.id!, name: "Test Team", color: "#000000")

        _ = try await TestSeed.createDriver(app: app, seasonID: season.id!, f1TeamID: team.id, firstName: "A", lastName: "One", driverNumber: 11, driverCode: "ONE")
        _ = try await TestSeed.createDriver(app: app, seasonID: season.id!, f1TeamID: team.id, firstName: "B", lastName: "Two", driverNumber: 22, driverCode: "TWO")

        try await app.test(.GET, "/api/drivers", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let drivers = try res.content.decode([Driver].self)
            XCTAssertEqual(drivers.count, 2)
            let codes = Set(drivers.map { $0.driverCode })
            XCTAssertTrue(codes.contains("ONE"))
            XCTAssertTrue(codes.contains("TWO"))
        })
    }
}
