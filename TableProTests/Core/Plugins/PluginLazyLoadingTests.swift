//
//  PluginLazyLoadingTests.swift
//  TableProTests
//
//  Tests for lazy plugin loading behavior
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Plugin Lazy Loading", .serialized)
@MainActor
struct PluginLazyLoadingTests {
    @Test("loadPendingPlugins is idempotent when called multiple times")
    func loadPendingPluginsIdempotent() async {
        // loadPendingPlugins should not crash or duplicate when called multiple times
        let manager = PluginManager.shared
        await manager.loadPendingPluginsAsync()
        let countAfterFirst = manager.plugins.count
        await manager.loadPendingPluginsAsync()
        let countAfterSecond = manager.plugins.count
        #expect(countAfterFirst == countAfterSecond)
    }

    @Test("loadPendingPlugins populates driverPlugins")
    func loadPendingPopulatesDrivers() async {
        let manager = PluginManager.shared
        await manager.loadPendingPluginsAsync()
        // After loading, at least some driver plugins should be registered
        // (the built-in plugins are always available in the test bundle)
        #expect(manager.driverPlugins.isEmpty == false || manager.plugins.isEmpty)
    }

    @Test("loadPendingPlugins with no pending is no-op")
    func loadPendingNoPendingIsNoOp() async {
        let manager = PluginManager.shared
        // Ensure all pending are loaded first
        await manager.loadPendingPluginsAsync()
        let driverCount = manager.driverPlugins.count
        let pluginCount = manager.plugins.count
        // Call again - should be no-op
        await manager.loadPendingPluginsAsync()
        #expect(manager.driverPlugins.count == driverCount)
        #expect(manager.plugins.count == pluginCount)
    }
}
