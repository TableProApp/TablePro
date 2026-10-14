//
//  PluginManagerInitialLoadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct PluginManagerInitialLoadTests {
    @MainActor
    private final class Flag {
        var isSet = false
    }

    private struct Fixture {
        let manager: PluginManager
        let clock: ManualClock
        let root: URL
        let defaults: EphemeralDefaults
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManagerInitialLoadTests-\(UUID().uuidString)", isDirectory: true)
        let defaults = try EphemeralDefaults()
        let clock = ManualClock()
        let manager = PluginManager(
            userDefaults: defaults.defaults,
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true),
            initialLoadClock: clock
        )
        return Fixture(manager: manager, clock: clock, root: root, defaults: defaults)
    }

    @Test("A wait before any load has started returns at once instead of sitting out its timeout")
    func returnsAtOnceWithoutAStartedLoad() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let clock = fixture.clock
        let returned = Flag()

        let waiter = Task {
            await manager.waitForInitialLoad()
            returned.isSet = true
        }
        // A wait that arms its timeout sleeps on the clock, which nothing here advances.
        try await waitUntil { returned.isSet || clock.pendingSleeperCount > 0 }

        #expect(returned.isSet)
        #expect(clock.pendingSleeperCount == 0)
        #expect(!manager.hasFinishedInitialLoad)
        clock.advance(by: .seconds(10))
        await waiter.value
    }

    @Test("A wait after loadPlugins() has started holds until that load finishes")
    func waitsForAStartedLoad() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager

        manager.loadPlugins()
        #expect(!manager.hasFinishedInitialLoad)

        // The timeout's clock never advances, so only the load finishing can end this wait.
        await manager.waitForInitialLoad()

        #expect(manager.hasFinishedInitialLoad)
    }
}
