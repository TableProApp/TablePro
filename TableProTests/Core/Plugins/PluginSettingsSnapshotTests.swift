//
//  PluginSettingsSnapshotTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("PluginSettingsSnapshot", .serialized)
struct PluginSettingsSnapshotTests {
    private struct TestOptions: Codable, Equatable {
        var flag = false
        var count = 0
    }

    private final class TestPlugin: SettablePlugin {
        static let settingsStorageId = "test.snapshot.holder"

        var settings = TestOptions() {
            didSet { saveSettings() }
        }

        func resetSettingsToDefaults() {
            settings = TestOptions()
        }
    }

    private final class BareDiscoverablePlugin: SettablePluginDiscoverable {
        func settingsView() -> AnyView? { nil }
    }

    private func cleanup() {
        PluginSettingsStorage(pluginId: TestPlugin.settingsStorageId).removeAll()
    }

    @Test("restore reverts captured plugins")
    func restoreReverts() {
        defer { cleanup() }
        let plugin = TestPlugin()
        plugin.settings = TestOptions(flag: true, count: 1)
        let snapshot = PluginSettingsSnapshot(plugins: [plugin])

        plugin.settings = TestOptions(flag: false, count: 9)
        snapshot.restore()

        #expect(plugin.settings == TestOptions(flag: true, count: 1))
    }

    @Test("recapture updates the rollback baseline")
    func recaptureUpdatesBaseline() {
        defer { cleanup() }
        let plugin = TestPlugin()
        plugin.settings = TestOptions(flag: true, count: 1)
        var snapshot = PluginSettingsSnapshot(plugins: [plugin])

        plugin.resetSettingsToDefaults()
        snapshot.recapture(plugin)
        plugin.settings = TestOptions(flag: true, count: 5)
        snapshot.restore()

        #expect(plugin.settings == TestOptions())
    }

    @Test("plugins without snapshot data are skipped")
    func skipsPluginsWithoutData() {
        defer { cleanup() }
        let bare = BareDiscoverablePlugin()
        let plugin = TestPlugin()
        plugin.settings = TestOptions(flag: true, count: 2)
        let snapshot = PluginSettingsSnapshot(plugins: [bare, plugin])

        plugin.settings = TestOptions(flag: false, count: 0)
        snapshot.restore()

        #expect(plugin.settings == TestOptions(flag: true, count: 2))
    }

    @Test("recapture ignores plugins that were not captured")
    func recaptureIgnoresUncaptured() {
        defer { cleanup() }
        let plugin = TestPlugin()
        plugin.settings = TestOptions(flag: true, count: 3)
        var snapshot = PluginSettingsSnapshot(plugins: [])

        snapshot.recapture(plugin)
        snapshot.restore()

        #expect(plugin.settings == TestOptions(flag: true, count: 3))
    }
}
