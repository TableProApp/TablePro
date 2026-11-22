import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ExtensionsPaneModelTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtensionsPaneModelTests-\(UUID().uuidString)", isDirectory: true)

    private func entry(
        _ id: String,
        name: String? = nil,
        capabilities: [PluginCapability] = [.databaseDriver],
        typeIds: [String] = [],
        exportFormatId: String? = nil,
        source: PluginSource = .builtIn,
        url: URL? = nil,
        bundle: Bundle = .main
    ) -> PluginEntry {
        PluginEntry(
            id: id,
            bundle: bundle,
            url: url ?? URL(fileURLWithPath: "/tmp/\(id).tableplugin"),
            source: source,
            name: name ?? id,
            version: "1.0",
            build: 1,
            pluginDescription: "",
            capabilities: capabilities,
            databaseTypeId: typeIds.first,
            additionalTypeIds: Array(typeIds.dropFirst()),
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: exportFormatId,
            importFormatId: nil
        )
    }

    private func rejected(_ name: String, bundleId: String? = nil, url: URL? = nil, isOutdated: Bool = true) -> RejectedPlugin {
        RejectedPlugin(
            url: url ?? URL(fileURLWithPath: "/tmp/\(UUID().uuidString).tableplugin"),
            bundleId: bundleId,
            registryId: nil,
            name: name,
            reason: "Built for an older PluginKit",
            isOutdated: isOutdated,
            providedDatabaseTypeIds: []
        )
    }

    private func snapshot(
        _ plugins: [PluginEntry],
        rejected: [RejectedPlugin] = [],
        needsRestart: Bool = false,
        staged: Set<String> = []
    ) -> ExtensionsSnapshot {
        ExtensionsPaneModel.makeSnapshot(
            plugins: plugins,
            rejected: rejected,
            needsRestart: needsRestart,
            staged: staged,
            manifest: nil,
            isUpdatingEnabled: false,
            canRemove: { _ in false }
        )
    }

    private func makeManager() -> PluginManager {
        PluginManager(builtInPluginsURL: nil, userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true))
    }

    private func makeContext(_ navigation: SettingsNavigationModel, registry: OfflineRegistry) -> SettingsPaneContext {
        SettingsPaneContext(
            pane: .plugins,
            settings: AppSettingsManager.shared,
            navigation: navigation,
            models: SettingsWindowModels(),
            registryClient: registry.client,
            presentError: { _, _ in }
        )
    }

    @Test("Every plugin lands in exactly one group, and one with no known first capability lands in Other")
    func everyPluginInOneGroup() {
        let plugins = [
            entry("driver", capabilities: [.databaseDriver]),
            entry("export", capabilities: [.exportFormat]),
            entry("import", capabilities: [.importFormat]),
            entry("inspector", capabilities: [.documentInspector]),
            entry("none", capabilities: []),
            entry("both", capabilities: [.exportFormat, .databaseDriver]),
        ]
        let groups = snapshot(plugins).groups

        #expect(groups.map(\.group) == [.drivers, .exports, .imports, .other])
        #expect(groups.flatMap(\.rows).map(\.id).sorted() == plugins.map(\.id).sorted())
        #expect(groups.first { $0.group == .exports }?.rows.map(\.id) == ["both", "export"])
        #expect(groups.first { $0.group == .other }?.rows.map(\.id) == ["inspector", "none"])
    }

    @Test("Rows sort by name the way Finder does, numbers by value and case ignored")
    func rowsSortLikeFinder() {
        let plugins = [
            entry("a", name: "PostgreSQL"),
            entry("b", name: "mysql"),
            entry("c", name: "Item 10"),
            entry("d", name: "Item 9"),
        ]
        #expect(snapshot(plugins).rows.map(\.name) == ["Item 9", "Item 10", "mysql", "PostgreSQL"])
    }

    @Test("The filter matches a type id, a format id, a group title, a rejected caption and a module summary")
    func filterMatchesEveryField() {
        let content = snapshot(
            [
                entry("pg", name: "PostgreSQL", typeIds: ["PostgreSQL", "Redshift"]),
                entry("xlsx", name: "Spreadsheet", capabilities: [.exportFormat], exportFormatId: "xlsx"),
            ],
            rejected: [rejected("Old Driver")]
        )

        #expect(content.filtered("redshift").groups.flatMap(\.rows).map(\.id) == ["pg"])
        #expect(content.filtered("XLSX").groups.flatMap(\.rows).map(\.id) == ["xlsx"])
        #expect(content.filtered("Export Formats").groups.map(\.group) == [.exports])
        // With no manifest yet the caption reads "Waiting for a compatible build".
        #expect(content.filtered("compatible").rejected.map(\.name) == ["Old Driver"])
        #expect(content.filtered("old").rejected.map(\.name) == ["Old Driver"])
        #expect(content.filtered("old").groups.isEmpty)
        #expect(content.filtered("breakpoints").modules == [.routineDebugger])
        #expect(content.filtered("zzz").isEmpty)
        #expect(content.filtered("zzz").isFiltering)
        #expect(!content.filtered("  ").isFiltering)
    }

    @Test("A plugin whose bundle also could not load is listed once, under Couldn't Load")
    func doubleListedPluginShownOnce() throws {
        let url = URL(fileURLWithPath: "/tmp/Broken.tableplugin")
        let result = snapshot(
            [entry("com.example.broken", url: url), entry("com.example.fine")],
            rejected: [rejected("Broken", bundleId: "com.example.broken", url: url)]
        )
        #expect(result.rows.map(\.id) == ["com.example.fine"])
        #expect(result.rejected.map(\.url) == [url])
    }

    @Test("A plugin route whose bundle could not load opens the Couldn't Load page")
    func pluginRouteOfRejectedBundleShowsRejectedPage() throws {
        let manager = makeManager()
        let registry = try OfflineRegistry()
        let model = ExtensionsPaneModel(manager: manager, registryClient: registry.client)
        let url = URL(fileURLWithPath: "/tmp/Broken-\(UUID().uuidString).tableplugin")
        manager.plugins = [entry("com.example.broken", url: url)]
        manager.rejectedPlugins = [rejected("Broken", bundleId: "com.example.broken", url: url)]

        guard case .rejected(let row) = model.page(for: .plugin(id: "com.example.broken")) else {
            Issue.record("expected the rejected page")
            return
        }
        #expect(row.url == url)
        guard case .unavailable = model.page(for: .plugin(id: "com.example.gone")) else {
            Issue.record("expected the unavailable page")
            return
        }
    }

    @Test("Relaunch explains removed plugins first, then staged updates")
    func relaunchReason() {
        #expect(snapshot([]).relaunch == nil)
        #expect(snapshot([], staged: ["a"]).relaunch == .updates)
        #expect(snapshot([], needsRestart: true).relaunch == .removed)
        #expect(snapshot([], needsRestart: true, staged: ["a"]).relaunch == .removed)
    }

    @Test("A row's status line shows the first state that applies")
    func rowStatusPrecedence() {
        #expect(ExtensionsPluginStatus(phase: .downloading(fraction: 0.5), isStaged: true, isBuiltIn: true, version: "1") == .downloading)
        #expect(ExtensionsPluginStatus(phase: .installing, isStaged: true, isBuiltIn: true, version: "1") == .installing)
        #expect(ExtensionsPluginStatus(phase: .failed("x"), isStaged: true, isBuiltIn: true, version: "1") == .failed)
        #expect(ExtensionsPluginStatus(phase: .completed, isStaged: true, isBuiltIn: true, version: "1") == .staged)
        #expect(ExtensionsPluginStatus(phase: nil, isStaged: false, isBuiltIn: true, version: "1") == .builtIn)
        #expect(ExtensionsPluginStatus(phase: nil, isStaged: false, isBuiltIn: false, version: "1.2") == .version("1.2"))
        #expect(ExtensionsPageStatus(phase: nil, isStaged: false) == nil)
        #expect(ExtensionsPageStatus(phase: .completed, isStaged: true) == .staged)
    }

    @Test("Only installs no row shows get an activity row, oldest first")
    func activitiesSkipRowsAndFinishedInstalls() {
        func install(_ id: String, order: Int, phase: PluginInstallTracker.Phase) -> PluginInstallTracker.Entry {
            PluginInstallTracker.Entry(
                pluginId: id,
                displayName: id,
                generation: UUID(),
                order: order,
                trigger: .user,
                retry: nil,
                phase: phase
            )
        }
        let entries = [
            "listed": install("listed", order: 1, phase: .installing),
            "file:/a.zip": install("file:/a.zip", order: 3, phase: .installing),
            "done": install("done", order: 2, phase: .completed),
            "broken": install("broken", order: 4, phase: .failed("no")),
        ]
        let activities = ExtensionsSnapshot.activities(in: entries, excluding: ["listed"])
        #expect(activities.map(\.pluginId) == ["file:/a.zip", "broken"])
    }

    @Test("Only zip and tableplugin files install, whatever the case of the extension")
    func onlyPluginFilesInstall() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.zip"),
            URL(fileURLWithPath: "/tmp/b.TablePlugin"),
            URL(fileURLWithPath: "/tmp/c.txt"),
            try #require(URL(string: "https://example.com/d.zip")),
        ]
        #expect(ExtensionsPaneModel.installableFiles(urls).map(\.lastPathComponent) == ["a.zip", "b.TablePlugin"])
    }

    @Test("A reveal asked for before the plugin loaded opens its page once the plugin is listed")
    func revealBeforeLoadFinishes() async throws {
        let manager = makeManager()
        let registry = try OfflineRegistry()
        let model = ExtensionsPaneModel(manager: manager, registryClient: registry.client)
        let navigation = SettingsNavigationModel(initial: .root(.plugins), isRouteAvailable: { route in
            guard case .plugin(let id) = route else { return true }
            return manager.plugins.contains { $0.id == id }
        })
        let context = makeContext(navigation, registry: registry)

        navigation.open(SettingsLocation(route: .plugin(id: "com.example.late")), recordsHistory: true)
        #expect(navigation.location == .root(.plugins))
        #expect(navigation.pendingPluginReveal?.pluginId == "com.example.late")

        manager.plugins = [entry("com.example.late")]
        context.filter?.query = "something"
        await model.revealPending(in: context)

        #expect(navigation.location.routes == [.plugin(id: "com.example.late")])
        #expect(navigation.pendingPluginReveal == nil)
        #expect(context.filter?.query == "")
    }

    @Test("A reveal with no id opens the first plugin waiting for an update")
    func revealWithoutIdOpensFirstOutdated() async throws {
        let manager = makeManager()
        let registry = try OfflineRegistry()
        let model = ExtensionsPaneModel(manager: manager, registryClient: registry.client)
        let broken = rejected("Broken", isOutdated: false)
        let outdated = rejected("Outdated")
        manager.rejectedPlugins = [broken, outdated]
        let navigation = SettingsNavigationModel(initial: .root(.plugins))
        let context = makeContext(navigation, registry: registry)

        navigation.requestPluginReveal(nil)
        await model.revealPending(in: context)

        #expect(navigation.location.routes == [.rejectedPlugin(outdated.url)])
    }

    @Test("A reveal is consumed but not pushed once the pane has moved into a page or away")
    func revealDroppedWhenNotAtRoot() async throws {
        let manager = makeManager()
        let registry = try OfflineRegistry()
        let model = ExtensionsPaneModel(manager: manager, registryClient: registry.client)
        manager.rejectedPlugins = [rejected("Outdated")]
        let navigation = SettingsNavigationModel(initial: .root(.plugins))
        let context = makeContext(navigation, registry: registry)

        navigation.push(.plugin(id: "com.example.open"), in: .plugins)
        navigation.requestPluginReveal(nil)
        await model.revealPending(in: context)
        #expect(navigation.location.routes == [.plugin(id: "com.example.open")])
        #expect(navigation.pendingPluginReveal == nil)

        navigation.select(.general)
        navigation.requestPluginReveal(nil)
        await model.revealPending(in: context)
        #expect(navigation.location == .root(.general))
    }

    @Test("An uninstall whose bundle cannot be removed keeps the plugin listed and asks for no relaunch")
    func uninstallFailureKeepsTheEntry() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager()
        let url = root.appendingPathComponent("Plugins/Driver.tableplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: url))
        manager.plugins = [entry("com.example.driver", source: .userInstalled, url: url, bundle: bundle)]

        await #expect(throws: CocoaError.self) {
            try await manager.uninstallPlugin(id: "com.example.driver") { _ in throw CocoaError(.fileWriteNoPermission) }
        }

        #expect(manager.plugins.map(\.id) == ["com.example.driver"])
        #expect(!manager.needsRestart)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An uninstall hands the bundle to the remover before it unlists the plugin")
    func uninstallRemovesTheBundleFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager()
        let url = root.appendingPathComponent("Plugins/Driver.tableplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: url))
        manager.plugins = [entry("com.example.driver", source: .userInstalled, url: url, bundle: bundle)]
        var listedWhileRemoving: [String] = []

        try await manager.uninstallPlugin(id: "com.example.driver") { _ in
            listedWhileRemoving = manager.plugins.map(\.id)
        }

        #expect(listedWhileRemoving == ["com.example.driver"])
        #expect(manager.plugins.isEmpty)
        #expect(manager.needsRestart)
    }

    @Test("Installing a loose bundle works on a copy and leaves the user's file where it was")
    func looseInstallLeavesTheSource() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true)
        let contents = source.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))

        let copy = try PluginManager.copyLooseBundle(at: source, into: root.appendingPathComponent("Staging/work", isDirectory: true))

        #expect(copy.lastPathComponent == "Driver.tableplugin")
        #expect(copy.standardizedFileURL != source.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/Info.plist").path))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Contents/Info.plist").path))
    }

    @Test("A declared display name is trimmed, and a blank one counts as none")
    func declaredDisplayName() {
        #expect(PluginManager.declaredDisplayName(in: ["CFBundleDisplayName": " CSV Export "]) == "CSV Export")
        #expect(PluginManager.declaredDisplayName(in: ["CFBundleDisplayName": "  "]) == nil)
        #expect(PluginManager.declaredDisplayName(in: [:]) == nil)
    }

    @Test("Every bundled plugin's Info.plist names it the way its class does, so the list shows it before its code loads")
    func bundledPluginsDeclareTheirName() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tableplugin" }
        #expect(!urls.isEmpty)

        for url in urls {
            let bundle = try #require(Bundle(url: url))
            let principal = try #require(bundle.principalClass as? any TableProPlugin.Type, "\(url.lastPathComponent)")
            let declared = PluginManager.declaredDisplayName(in: PluginManager.infoPlist(at: url))
            #expect(declared == principal.pluginName, "\(url.lastPathComponent)")
        }
    }
}
