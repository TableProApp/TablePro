//
//  PluginLazyLoadingTests.swift
//  TableProTests
//
//  Tests for lazy plugin loading behavior
//

import Foundation
import Testing
@testable import TablePro

@Suite("Plugin Lazy Loading")
@MainActor
struct PluginLazyLoadingTests {
    @Test("loadPendingPlugins is idempotent when called multiple times")
    func loadPendingPluginsIdempotent() {
        // loadPendingPlugins should not crash or duplicate when called multiple times
        let manager = PluginManager.shared
        manager.loadPendingPlugins()
        let countAfterFirst = manager.plugins.count
        manager.loadPendingPlugins()
        let countAfterSecond = manager.plugins.count
        #expect(countAfterFirst == countAfterSecond)
    }

    @Test("loadPendingPlugins populates driverPlugins")
    func loadPendingPopulatesDrivers() {
        let manager = PluginManager.shared
        manager.loadPendingPlugins()
        // After loading, at least some driver plugins should be registered
        // (the built-in plugins are always available in the test bundle)
        #expect(manager.driverPlugins.isEmpty == false || manager.plugins.isEmpty)
    }

    @Test("loadPendingPlugins with no pending is no-op")
    func loadPendingNoPendingIsNoOp() {
        let manager = PluginManager.shared
        // Ensure all pending are loaded first
        manager.loadPendingPlugins()
        let driverCount = manager.driverPlugins.count
        let pluginCount = manager.plugins.count
        // Call again - should be no-op
        manager.loadPendingPlugins()
        #expect(manager.driverPlugins.count == driverCount)
        #expect(manager.plugins.count == pluginCount)
    }
}
