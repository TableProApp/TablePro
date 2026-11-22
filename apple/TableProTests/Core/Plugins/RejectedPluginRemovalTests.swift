import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class TrashRecorder {
    var trashed: [URL] = []
}

@MainActor
struct RejectedPluginRemovalTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RejectedPluginRemovalTests-\(UUID().uuidString)", isDirectory: true)

    private func makeBundle(in directory: URL) throws -> RejectedPlugin {
        let url = directory.appendingPathComponent("Broken.tableplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RejectedPlugin(
            url: url,
            bundleId: "com.example.broken",
            registryId: nil,
            name: "Broken",
            reason: "Could not be loaded",
            isOutdated: false,
            providedDatabaseTypeIds: []
        )
    }

    @Test("A rejected plugin in the user's folder moves to the Trash and leaves the list")
    func userPluginMovesToTheTrash() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let userPlugins = root.appendingPathComponent("Plugins", isDirectory: true)
        let plugin = try makeBundle(in: userPlugins)
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: userPlugins)
        manager.rejectedPlugins = [plugin]
        let recorder = TrashRecorder()

        #expect(manager.canRemoveRejectedPlugin(plugin))
        try manager.removeRejectedPlugin(plugin) { recorder.trashed.append($0) }

        #expect(recorder.trashed == [plugin.url])
        #expect(manager.rejectedPlugins.isEmpty)
    }

    @Test("Removing a rejected plugin also drops the listed copy of the same bundle")
    func removalDropsTheListedCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let userPlugins = root.appendingPathComponent("Plugins", isDirectory: true)
        let plugin = try makeBundle(in: userPlugins)
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: userPlugins)
        manager.rejectedPlugins = [plugin]
        manager.plugins = [PluginEntry(
            id: "com.example.broken",
            bundle: Bundle.main,
            url: plugin.url,
            source: .userInstalled,
            name: "Broken",
            version: "1.0",
            pluginDescription: "",
            capabilities: [.databaseDriver],
            databaseTypeId: nil,
            additionalTypeIds: [],
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: nil,
            importFormatId: nil
        )]
        let recorder = TrashRecorder()

        try manager.removeRejectedPlugin(plugin) { recorder.trashed.append($0) }

        #expect(recorder.trashed == [plugin.url])
        #expect(manager.rejectedPlugins.isEmpty)
        #expect(manager.plugins.isEmpty)
    }

    @Test("A rejected plugin outside the user's folder, such as one inside the app, is refused and kept")
    func bundledPluginIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let userPlugins = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: userPlugins, withIntermediateDirectories: true)
        let plugin = try makeBundle(in: root.appendingPathComponent("TablePro.app/Contents/PlugIns", isDirectory: true))
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: userPlugins)
        manager.rejectedPlugins = [plugin]
        let recorder = TrashRecorder()

        #expect(!manager.canRemoveRejectedPlugin(plugin))
        let error = #expect(throws: PluginError.self) {
            try manager.removeRejectedPlugin(plugin) { recorder.trashed.append($0) }
        }
        guard case .cannotUninstallBuiltIn = error else {
            Issue.record("expected cannotUninstallBuiltIn, got \(String(describing: error))")
            return
        }

        #expect(recorder.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: plugin.url.path))
        #expect(manager.rejectedPlugins.map(\.url) == [plugin.url])
    }

    @Test("A path that climbs out of the user's folder is refused")
    func climbingPathIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let userPlugins = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: userPlugins, withIntermediateDirectories: true)
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: userPlugins)
        let escaping = RejectedPlugin(
            url: userPlugins.appendingPathComponent("../Other.tableplugin"),
            bundleId: nil,
            registryId: nil,
            name: "Other",
            reason: "",
            isOutdated: false,
            providedDatabaseTypeIds: []
        )

        #expect(!manager.canRemoveRejectedPlugin(escaping))
    }
}
