import Foundation
import Testing
@testable import TablePro

@Suite("PluginManager needsRestart State", .serialized)
@MainActor
struct NeedsRestartPersistenceTests {
    private let defaults = UserDefaults.standard
    private let needsRestartKey = "com.TablePro.needsRestart"

    @Test("needsRestart defaults to false")
    func needsRestartDefaultsToFalse() {
        #expect(PluginManager.shared.needsRestart == false)
    }

    @Test("needsRestart value matches UserDefaults")
    func needsRestartMatchesUserDefaults() {
        let currentValue = PluginManager.shared.needsRestart
        let defaultsValue = defaults.bool(forKey: needsRestartKey)
        #expect(currentValue == defaultsValue)
    }

    @Test("loadPendingPlugins with no pending plugins does not set needsRestart")
    func loadPendingPluginsKeepsFalse() {
        PluginManager.shared.loadPendingPlugins()
        #expect(PluginManager.shared.needsRestart == false)
    }

    @Test("UserDefaults key for needsRestart uses expected value")
    func needsRestartKeyValue() {
        #expect(needsRestartKey == "com.TablePro.needsRestart")
    }
}
