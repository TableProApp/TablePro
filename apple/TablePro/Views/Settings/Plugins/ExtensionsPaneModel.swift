import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

internal enum ExtensionsPluginGroup: CaseIterable, Hashable, Sendable {
    case drivers
    case exports
    case imports
    case other

    // The first capability decides; none, or one this build does not know, lands in Other.
    internal init(capabilities: [PluginCapability]) {
        switch capabilities.first {
        case .databaseDriver: self = .drivers
        case .exportFormat: self = .exports
        case .importFormat: self = .imports
        default: self = .other
        }
    }

    internal var title: String {
        switch self {
        case .drivers: String(localized: "Database Drivers")
        case .exports: String(localized: "Export Formats")
        case .imports: String(localized: "Import Formats")
        case .other: String(localized: "Other")
        }
    }
}

internal struct ExtensionsPluginRow: Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let iconName: String
    let isBuiltIn: Bool
    let version: String
    let typeIds: [String]
    let formatIds: [String]
    let group: ExtensionsPluginGroup
    let isStaged: Bool

    var isDriver: Bool { !typeIds.isEmpty }
}

internal struct ExtensionsPluginSection: Equatable, Identifiable, Sendable {
    let group: ExtensionsPluginGroup
    let rows: [ExtensionsPluginRow]

    var id: ExtensionsPluginGroup { group }
}

internal enum ExtensionsRejectedAction: Equatable, Sendable {
    case update(registryId: String)
    case appUpdate
    case retry
    case noAction
}

internal struct ExtensionsRejectedRow: Equatable, Identifiable, Sendable {
    let url: URL
    let name: String
    let iconName: String
    let reason: String
    let caption: String
    let severity: NoticeSeverity
    let action: ExtensionsRejectedAction
    let canRemove: Bool
    let bundleId: String?
    // The tracker keys a repair by the registry id, so the row finds its own download.
    let trackerId: String?

    var id: URL { url }
}

internal enum ExtensionsRelaunchReason: Equatable, Sendable {
    case removed
    case updates

    var text: String {
        switch self {
        case .removed: String(localized: "Removed plugins stay loaded until TablePro relaunches.")
        case .updates: String(localized: "Plugin updates install when TablePro relaunches.")
        }
    }
}

internal enum ExtensionsPluginStatus: Equatable, Sendable {
    case downloading
    case installing
    case failed
    case staged
    case builtIn
    case version(String)

    init(phase: PluginInstallTracker.Phase?, isStaged: Bool, isBuiltIn: Bool, version: String) {
        switch phase {
        case .downloading?: self = .downloading
        case .installing?: self = .installing
        case .failed?: self = .failed
        case .completed?, nil:
            if isStaged {
                self = .staged
            } else if isBuiltIn {
                self = .builtIn
            } else {
                self = .version(version)
            }
        }
    }

    var text: String {
        switch self {
        case .downloading: String(localized: "Downloading update…")
        case .installing: String(localized: "Installing update…")
        case .failed: String(localized: "Update failed")
        case .staged: String(localized: "Updates when TablePro relaunches")
        case .builtIn: String(localized: "Built-in")
        case .version(let version): String(format: String(localized: "Version %@"), version)
        }
    }
}

internal enum ExtensionsPageStatus: Equatable, Sendable {
    case running(PluginInstallTracker.Phase)
    case failed(String)
    case staged

    init?(phase: PluginInstallTracker.Phase?, isStaged: Bool) {
        switch phase {
        case .downloading?, .installing?:
            guard let phase else { return nil }
            self = .running(phase)
        case .failed(let reason)?:
            self = .failed(reason)
        case .completed?, nil:
            guard isStaged else { return nil }
            self = .staged
        }
    }
}

internal struct ExtensionsFilteredContent: Equatable {
    let groups: [ExtensionsPluginSection]
    let rejected: [ExtensionsRejectedRow]
    let modules: [AppModule]
    let isFiltering: Bool

    var isEmpty: Bool { groups.isEmpty && rejected.isEmpty && modules.isEmpty }
}

internal struct ExtensionsSnapshot: Equatable, Sendable {
    var groups: [ExtensionsPluginSection] = []
    var rejected: [ExtensionsRejectedRow] = []
    var relaunch: ExtensionsRelaunchReason?

    var rows: [ExtensionsPluginRow] { groups.flatMap(\.rows) }

    // Tracker entries a row already shows; any other running or failed entry gets an activity row.
    var trackedIds: Set<String> {
        Set(rows.map(\.id)).union(rejected.compactMap(\.trackerId)).union(rejected.compactMap(\.bundleId))
    }

    func filtered(_ query: String, modules: [AppModule] = AppModule.allCases) -> ExtensionsFilteredContent {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return ExtensionsFilteredContent(groups: groups, rejected: rejected, modules: modules, isFiltering: false)
        }
        let matches: (String) -> Bool = { $0.localizedStandardContains(needle) }
        let filteredGroups = groups.compactMap { section -> ExtensionsPluginSection? in
            let rows = matches(section.group.title) ? section.rows : section.rows.filter { row in
                matches(row.name) || row.typeIds.contains(where: matches) || row.formatIds.contains(where: matches)
            }
            return rows.isEmpty ? nil : ExtensionsPluginSection(group: section.group, rows: rows)
        }
        return ExtensionsFilteredContent(
            groups: filteredGroups,
            rejected: rejected.filter { matches($0.name) || matches($0.caption) },
            modules: modules.filter { matches($0.title) || matches($0.summary) },
            isFiltering: true
        )
    }

    static func activities(
        in entries: [String: PluginInstallTracker.Entry],
        excluding trackedIds: Set<String>
    ) -> [PluginInstallTracker.Entry] {
        entries.values
            .filter { entry in
                guard !trackedIds.contains(entry.pluginId) else { return false }
                if case .completed = entry.phase { return false }
                return true
            }
            .sorted { $0.order < $1.order }
    }
}

internal enum ExtensionsPage {
    case plugin(PluginEntry, isStaged: Bool)
    case rejected(ExtensionsRejectedRow)
    case unavailable
}

// Owns the pane's view of the plugin manager for the window's lifetime, shared by the root and its pages.
@MainActor
internal final class ExtensionsPaneModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExtensionsPane")

    @Published private(set) var snapshot = ExtensionsSnapshot()
    @Published private(set) var retrying: Set<URL> = []
    @Published private(set) var retryFailures: Set<URL> = []

    let manager: PluginManager
    let registryClient: RegistryClient
    private(set) var plugins: [PluginEntry] = []
    private(set) var stagedPluginIds: Set<String> = []
    private var subscription: AnyCancellable?

    init(manager: PluginManager = .shared, registryClient: RegistryClient) {
        self.manager = manager
        self.registryClient = registryClient
        // @Published sends the new value before storing it, so the inputs come from the publishers, never the manager.
        subscription = manager.$plugins
            .combineLatest(manager.$rejectedPlugins, manager.$needsRestart, manager.$stagedPluginIds)
            .combineLatest(registryClient.$manifest)
            .sink { [weak self] inputs, manifest in
                MainActor.assumeIsolated {
                    self?.apply(
                        plugins: inputs.0,
                        rejected: inputs.1,
                        needsRestart: inputs.2,
                        staged: inputs.3,
                        manifest: manifest
                    )
                }
            }
    }

    private func apply(
        plugins: [PluginEntry],
        rejected: [RejectedPlugin],
        needsRestart: Bool,
        staged: Set<String>,
        manifest: RegistryManifest?
    ) {
        self.plugins = plugins
        stagedPluginIds = staged
        let next = Self.makeSnapshot(
            plugins: plugins,
            rejected: rejected,
            needsRestart: needsRestart,
            staged: staged,
            manifest: manifest,
            isUpdatingEnabled: manager.isUpdatingEnabled,
            canRemove: { [manager] in manager.canRemoveRejectedPlugin($0) }
        )
        if next != snapshot {
            snapshot = next
        }
    }

    static func makeSnapshot(
        plugins: [PluginEntry],
        rejected: [RejectedPlugin],
        needsRestart: Bool,
        staged: Set<String>,
        manifest: RegistryManifest?,
        isUpdatingEnabled: Bool,
        canRemove: (RejectedPlugin) -> Bool
    ) -> ExtensionsSnapshot {
        let rejectedURLs = Set(rejected.map(\.url))
        let rows = plugins
            .filter { !rejectedURLs.contains($0.url) }
            .map { row(for: $0, isStaged: staged.contains($0.id)) }
        let groups = ExtensionsPluginGroup.allCases.compactMap { group -> ExtensionsPluginSection? in
            let members = rows
                .filter { $0.group == group }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return members.isEmpty ? nil : ExtensionsPluginSection(group: group, rows: members)
        }
        let rejectedRows = rejected
            .map { rejectedRow(for: $0, manifest: manifest, isUpdatingEnabled: isUpdatingEnabled, canRemove: canRemove($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let relaunch: ExtensionsRelaunchReason?
        if needsRestart {
            relaunch = .removed
        } else if !staged.isEmpty {
            relaunch = .updates
        } else {
            relaunch = nil
        }
        return ExtensionsSnapshot(groups: groups, rejected: rejectedRows, relaunch: relaunch)
    }

    private static func row(for entry: PluginEntry, isStaged: Bool) -> ExtensionsPluginRow {
        ExtensionsPluginRow(
            id: entry.id,
            url: entry.url,
            name: entry.name,
            iconName: entry.pluginIconName,
            isBuiltIn: entry.source == .builtIn,
            version: entry.version,
            typeIds: (entry.databaseTypeId.map { [$0] } ?? []) + entry.additionalTypeIds,
            formatIds: [entry.exportFormatId, entry.importFormatId].compactMap { $0 },
            group: ExtensionsPluginGroup(capabilities: entry.capabilities),
            isStaged: isStaged
        )
    }

    private static func rejectedRow(
        for plugin: RejectedPlugin,
        manifest: RegistryManifest?,
        isUpdatingEnabled: Bool,
        canRemove: Bool
    ) -> ExtensionsRejectedRow {
        let action = PluginManager.rejectedAction(
            registryPlugin: PluginManager.registryPlugin(for: plugin, in: manifest),
            manifestLoaded: manifest != nil,
            kits: PluginManager.compatibleKits
        )
        let status = RejectedPluginStatus(action: action)
        let rowAction: ExtensionsRejectedAction
        switch action {
        case .updateAvailable(let registryPlugin): rowAction = .update(registryId: registryPlugin.id)
        case .requiresAppUpdate: rowAction = .appUpdate
        case .awaitingCompatibleBuild: rowAction = isUpdatingEnabled ? .retry : .noAction
        case .notInRegistry: rowAction = .noAction
        }
        let resolvedId = manifest.flatMap { PluginManager.resolveRegistryId(for: plugin, in: $0) }
        return ExtensionsRejectedRow(
            url: plugin.url,
            name: plugin.name,
            iconName: PluginManager.iconName(forPrimaryTypeId: plugin.providedDatabaseTypeIds.first),
            reason: plugin.reason,
            caption: status.caption,
            severity: status.severity,
            action: rowAction,
            canRemove: canRemove,
            bundleId: plugin.bundleId,
            trackerId: resolvedId ?? plugin.registryId ?? plugin.bundleId
        )
    }

    // A plugin row whose bundle could not load shows that page; a rejected route whose bundle has since loaded shows it.
    func page(for route: SettingsRoute) -> ExtensionsPage {
        switch route {
        case .plugin(let id):
            guard let entry = plugins.first(where: { $0.id == id }) else { return .unavailable }
            if let row = snapshot.rejected.first(where: { $0.url == entry.url }) { return .rejected(row) }
            return .plugin(entry, isStaged: stagedPluginIds.contains(id))
        case .rejectedPlugin(let url):
            if let row = snapshot.rejected.first(where: { $0.url == url }) { return .rejected(row) }
            if let entry = plugins.first(where: { $0.url == url }) {
                return .plugin(entry, isStaged: stagedPluginIds.contains(entry.id))
            }
            return .unavailable
        case .page, .aiProvider, .team:
            return .unavailable
        }
    }

    // Waits for the list, so a request made before it loaded still finds its plugin.
    func revealPending(in context: SettingsPaneContext) async {
        guard context.navigation.pendingPluginReveal != nil else { return }
        await manager.waitForInitialLoad()
        guard !Task.isCancelled, let request = context.navigation.consumePluginReveal() else { return }
        guard context.isCurrent, context.navigation.location.routes.isEmpty,
              let target = PluginListSelection.revealTarget(
                  pluginId: request.pluginId,
                  loadedIds: manager.plugins.map(\.id),
                  rejected: manager.rejectedPlugins
              ) else { return }
        context.filter?.query = ""
        context.navigation.push(target.route, in: context.pane)
    }

    nonisolated static func installableFiles(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            url.isFileURL && ["zip", "tableplugin"].contains(url.pathExtension.lowercased())
        }
    }

    // Returns false when no file is a plugin, so a drop of anything else is refused.
    @discardableResult
    func install(_ urls: [URL], context: SettingsPaneContext) -> Bool {
        let files = Self.installableFiles(urls)
        guard !files.isEmpty else { return false }
        Task { await installFiles(files, context: context) }
        return true
    }

    private func installFiles(_ files: [URL], context: SettingsPaneContext) async {
        var installed: [PluginEntry] = []
        for url in files {
            do {
                installed.append(try await manager.installPlugin(from: url))
            } catch {
                Self.logger.info("A plugin file did not install: \(error.localizedDescription)")
            }
        }
        // Several files, or a user who moved on, stay where they are.
        guard files.count == 1, let entry = installed.first, context.navigation.location.routes.isEmpty else { return }
        context.navigation.push(.plugin(id: entry.id), in: context.pane)
    }

    func retryInstall(_ entry: PluginInstallTracker.Entry, context: SettingsPaneContext, replacing route: SettingsRoute? = nil) {
        switch entry.retry {
        case .registry(let registryPlugin):
            update(registryPlugin, context: context, replacing: route)
        case .file(let url):
            install([url], context: context)
        case nil:
            break
        }
    }

    func registryPlugin(id: String) -> RegistryPlugin? {
        registryClient.manifest?.plugins.first { $0.id == id }
    }

    // A rejected plugin that installed is a loaded one now, so its page takes the loaded route.
    func update(_ registryPlugin: RegistryPlugin, context: SettingsPaneContext, replacing route: SettingsRoute? = nil) {
        Task {
            let result = await manager.performRegistryUpdate(registryPlugin)
            guard case .succeeded(let entry) = result, let route else { return }
            Self.replace(route, with: .plugin(id: entry.id), in: context)
        }
    }

    func retryRejected(_ url: URL) {
        guard !retrying.contains(url) else { return }
        retrying.insert(url)
        retryFailures.remove(url)
        Task {
            let reached = await manager.retryRejectedPluginRepairs(registryClient: registryClient)
            retrying.remove(url)
            if !reached {
                retryFailures.insert(url)
            }
        }
    }

    func uninstall(_ row: ExtensionsPluginRow, context: SettingsPaneContext) {
        uninstall(id: row.id, name: row.name, isDriver: row.isDriver, context: context)
    }

    func uninstall(id: String, name: String, isDriver: Bool, context: SettingsPaneContext) {
        Task {
            var message = String(localized: "The plugin moves to the Trash and its settings are deleted. It stays loaded until TablePro relaunches.")
            if isDriver {
                message += " " + String(localized: "Saved connections that use it stay in your library.")
            }
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Uninstall “%@”?"), name),
                message: message,
                confirmButton: String(localized: "Uninstall"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }
            do {
                try await manager.uninstallPlugin(id: id) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            } catch {
                context.presentError(title: String(localized: "Couldn't Uninstall"), message: error.localizedDescription)
                return
            }
            context.navigation.removeRoute(.plugin(id: id))
        }
    }

    func moveToTrash(_ url: URL, context: SettingsPaneContext) {
        guard let plugin = manager.rejectedPlugins.first(where: { $0.url == url }) else { return }
        Task {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(format: String(localized: "Move “%@” to the Trash?"), plugin.name),
                message: String(localized: "The plugin can't be loaded. You can put it back from the Trash."),
                confirmButton: String(localized: "Move to Trash"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }
            do {
                try manager.removeRejectedPlugin(plugin)
            } catch {
                context.presentError(title: String(localized: "Couldn't Move to Trash"), message: error.localizedDescription)
                return
            }
            context.navigation.removeRoute(.rejectedPlugin(url))
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func replace(_ old: SettingsRoute, with new: SettingsRoute, in context: SettingsPaneContext) {
        let wasShown = context.isCurrent && context.navigation.location.routes.last == old
        context.navigation.removeRoute(old)
        if wasShown {
            context.navigation.push(new, in: context.pane)
        }
    }
}
