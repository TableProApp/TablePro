import Testing
@testable import TablePro

@Suite("PluginManager needsRestart State", .serialized)
@MainActor
struct NeedsRestartPersistenceTests {
    @Test("loadPendingPlugins with no pending plugins does not set needsRestart")
    func loadPendingPluginsKeepsFalse() async {
        await PluginManager.shared.loadPendingPluginsAsync()
        #expect(PluginManager.shared.needsRestart == false)
    }
}
