import Foundation
@testable import TablePro
import Testing

struct PluginListSelectionTests {
    private func rejected(bundleId: String?, registryId: String? = nil, isOutdated: Bool = true) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).tableplugin"),
            bundleId: bundleId,
            registryId: registryId,
            name: "Driver",
            reason: "Built for an older PluginKit",
            isOutdated: isOutdated,
            providedDatabaseTypeIds: []
        )
    }

    @Test("A loaded plugin wins over a rejected copy with the same id")
    func loadedWins() {
        let copy = rejected(bundleId: "com.example.driver")
        let target = PluginListSelection.revealTarget(
            pluginId: "com.example.driver",
            loadedIds: ["com.example.driver"],
            rejected: [copy]
        )
        #expect(target == .plugin("com.example.driver"))
    }

    @Test("A connection failure naming a plugin that could not load selects its row")
    func rejectedByBundleOrRegistryId() {
        let byBundle = rejected(bundleId: "com.example.driver")
        let byRegistry = rejected(bundleId: nil, registryId: "com.example.other")
        #expect(
            PluginListSelection.revealTarget(pluginId: "com.example.driver", loadedIds: [], rejected: [byBundle, byRegistry])
                == .rejected(byBundle.url)
        )
        #expect(
            PluginListSelection.revealTarget(pluginId: "com.example.other", loadedIds: [], rejected: [byBundle, byRegistry])
                == .rejected(byRegistry.url)
        )
    }

    @Test("A failure that names no plugin selects the first one waiting for an update")
    func noIdPicksTheFirstOutdated() {
        let broken = rejected(bundleId: "com.example.broken", isOutdated: false)
        let outdated = rejected(bundleId: "com.example.outdated")
        #expect(
            PluginListSelection.revealTarget(pluginId: nil, loadedIds: [], rejected: [broken, outdated])
                == .rejected(outdated.url)
        )
        #expect(PluginListSelection.revealTarget(pluginId: nil, loadedIds: [], rejected: []) == nil)
    }

    @Test("An unknown id selects nothing")
    func unknownIdSelectsNothing() {
        #expect(
            PluginListSelection.revealTarget(pluginId: "com.example.none", loadedIds: ["a"], rejected: [rejected(bundleId: "b")])
                == nil
        )
    }

    @Test("Only a plugin missing from the registry reads as an error")
    func statusSeverity() {
        #expect(RejectedPluginStatus(action: .awaitingCompatibleBuild).severity == .warning)
        #expect(RejectedPluginStatus(action: .requiresAppUpdate).severity == .warning)
        #expect(RejectedPluginStatus(action: .notInRegistry).severity == .error)
    }
}
