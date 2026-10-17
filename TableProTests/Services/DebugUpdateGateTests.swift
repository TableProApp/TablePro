import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct DebugUpdateGateTests {
    @Test("The Debug test host has updating turned off")
    func debugBuildDisablesUpdating() {
        #expect(!SoftwareUpdater.isUpdatingEnabled)
    }

    @Test("Starting the updater in Debug leaves Check for Updates disabled")
    func startLeavesCheckForUpdatesDisabled() {
        SoftwareUpdater.shared.start()
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")

        #expect(!SoftwareUpdater.shared.canCheckForUpdates)
        #expect(!AppDelegate().validateMenuItem(item))
    }

    @Test("A Debug plugin load starts neither the plugin update pass nor its network monitor")
    func pluginLoadSkipsTheUpdatePass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugUpdateGateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try EphemeralDefaults()
        let manager = PluginManager(
            userDefaults: defaults.defaults,
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true)
        )

        manager.loadPlugins()
        await manager.waitForInitialLoad()

        #expect(manager.hasFinishedInitialLoad)
        #expect(manager.reconciliationTask == nil)
        #expect(manager.pluginNetworkMonitor == nil)
    }
}
