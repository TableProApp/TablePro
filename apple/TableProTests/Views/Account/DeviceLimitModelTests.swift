//
//  DeviceLimitModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct DeviceLimitModelTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    nonisolated private static let offlineUntil = "2027-01-15T00:00:00Z"

    private static func fixtureAtTheLimit() async throws -> AccountFixture {
        let fixture = try AccountFixture(now: { Self.now })
        await fixture.server.set {
            $0.deviceLimitReached = true
            $0.limitHolders = [
                FakeAccountServer.device(
                    id: "dev_linux", name: "Workstation", machineID: String(repeating: "1", count: 64),
                    platform: "linux", osVersion: "Fedora 43"
                ),
                FakeAccountServer.device(
                    id: "dev_air", name: "Air-gapped Mac", machineID: String(repeating: "2", count: 64),
                    offlineUntil: Self.offlineUntil
                ),
                FakeAccountServer.device(id: "dev_mini", name: "Mac mini", machineID: String(repeating: "3", count: 64))
            ]
            $0.devices += $0.limitHolders
        }
        try await fixture.signIn()
        return fixture
    }

    @Test("The sheet lists the 3 devices holding the slots, and reads offline_until from GET /v2/devices")
    func rowsCarryOfflineUntil() async throws {
        let fixture = try await Self.fixtureAtTheLimit()
        let model = DeviceLimitModel(services: fixture.services, now: { Self.now })
        #expect(model.rows.map { $0.name } == ["Workstation", "Air-gapped Mac", "Mac mini"])
        #expect(model.rows.allSatisfy { $0.offlineUntil == nil }, "The problem body carries no offline_until")

        await model.load()

        let until = try Date(Self.offlineUntil, strategy: .iso8601)
        #expect(model.rows.map { $0.offlineUntil } == [nil, until, nil])
        #expect(model.rows.first?.system == "Fedora 43")
        #expect(!model.isResolved)
    }

    @Test("Removing a device frees the slot, and the refresh that follows unlocks the plan on this Mac")
    func removeResolves() async throws {
        let fixture = try await Self.fixtureAtTheLimit()
        let model = DeviceLimitModel(services: fixture.services, now: { Self.now })
        await model.load()
        let row = try #require(model.rows.first { $0.id == "dev_mini" })

        await model.remove(row)

        #expect(model.isResolved)
        #expect(model.failure == nil)
        #expect(fixture.access.isAvailable(.iCloudSync))
        #expect(model.rows.count == 3, "The rows stay while the sheet closes")
    }

    @Test("A device whose offline file is valid is refused with the reason, and the app stays on Free")
    func offlineDeviceIsRefused() async throws {
        let fixture = try await Self.fixtureAtTheLimit()
        let model = DeviceLimitModel(services: fixture.services, now: { Self.now })
        let row = try #require(model.rows.first { $0.id == "dev_air" })

        await model.remove(row)

        #expect(model.failure == AccountError.server(status: 409, code: "offline_file_active").deviceRemovalDescription)
        #expect(!model.isResolved)
        #expect(fixture.access.check(.iCloudSync) == .notIncluded)
    }
}
