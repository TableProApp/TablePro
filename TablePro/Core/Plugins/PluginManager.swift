//
//  PluginManager.swift
//  TablePro
//

import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

@MainActor @Observable
final class PluginManager {
    static let shared = PluginManager()
    static let currentPluginKitVersion = 2
    private static let disabledPluginsKey = "com.TablePro.disabledPlugins"
    private static let legacyDisabledPluginsKey = "disabledPlugins"

    private(set) var plugins: [PluginEntry] = []

    private(set) var isInstalling = false

    /// True once the initial plugin discovery + loading pass has completed.
    private(set) var hasFinishedInitialLoad = false

    private static let needsRestartKey = "com.TablePro.needsRestart"

    private var _needsRestart: Bool = UserDefaults.standard.bool(
        forKey: needsRestartKey
    ) {
        didSet { UserDefaults.standard.set(_needsRestart, forKey: Self.needsRestartKey) }
    }

    var needsRestart: Bool { _needsRestart }

    private(set) var driverPlugins: [String: any DriverPlugin] = [:]

    private(set) var exportPlugins: [String: any ExportFormatPlugin] = [:]

    private(set) var importPlugins: [String: any ImportFormatPlugin] = [:]

    private(set) var pluginInstances: [String: any TableProPlugin] = [:]

    private var builtInPluginsDir: URL? { Bundle.main.builtInPlugInsURL }

    private var userPluginsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    var disabledPluginIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledPluginsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.disabledPluginsKey) }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginManager")

    private var pendingPluginURLs: [(url: URL, source: PluginSource)] = []

    private var queryBuildingDriverCache: [String: (any PluginDatabaseDriver)?] = [:]

    private init() {}

    // MARK: - Registry Metadata

    private struct RegistryMetadata: Codable {
        let version: String
        let pluginId: String
    }

    nonisolated private static func metadataURL(for pluginURL: URL) -> URL {
        pluginURL.deletingLastPathComponent()
            .appendingPathComponent(pluginURL.lastPathComponent + ".metadata.json")
    }

    nonisolated private static func readRegistryVersion(for pluginURL: URL) -> String? {
        let url = metadataURL(for: pluginURL)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(RegistryMetadata.self, from: data) else {
            return nil
        }
        return metadata.version
    }

    func saveRegistryMetadata(version: String, pluginId: String, pluginURL: URL) {
        let metadata = RegistryMetadata(version: version, pluginId: pluginId)
        let url = Self.metadataURL(for: pluginURL)
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save registry metadata for \(pluginId): \(error.localizedDescription)")
        }
    }

    func updatePluginVersion(id: String, version: String) {
        if let index = plugins.firstIndex(where: { $0.id == id }) {
            plugins[index].version = version
        }
    }

    private func removeRegistryMetadata(for pluginURL: URL) {
        let url = Self.metadataURL(for: pluginURL)
        try? FileManager.default.removeItem(at: url)
    }

    private func migrateDisabledPluginsKey() {
        let defaults = UserDefaults.standard
        if let legacy = defaults.stringArray(forKey: Self.legacyDisabledPluginsKey) {
            if defaults.stringArray(forKey: Self.disabledPluginsKey) == nil {
                defaults.set(legacy, forKey: Self.disabledPluginsKey)
            }
            defaults.removeObject(forKey: Self.legacyDisabledPluginsKey)
        }
    }

    // MARK: - Loading

    /// Discover and load all plugins. Discovery is synchronous (reads Info.plist),
    /// then bundle loading runs on a background thread to avoid blocking the UI.
    /// Only the final registration into dictionaries happens on MainActor.
    func loadPlugins() {
        migrateDisabledPluginsKey()
        discoverAllPlugins()
        let pending = pendingPluginURLs
        Task {
            let loaded = await Self.loadBundlesOffMain(pending)
            self.pendingPluginURLs.removeAll()
            self._needsRestart = false
            self.registerLoadedPlugins(loaded)
            self.validateDependencies()
            self.hasFinishedInitialLoad = true
            Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s), \(self.importPlugins.count) import format(s)")
        }
    }

    /// Holds the result of loading a single plugin bundle off the main thread.
    /// Bundle is not formally Sendable but is thread-safe for property reads after load().
    private struct LoadedBundle: @unchecked Sendable {
        let url: URL
        let source: PluginSource
        let bundle: Bundle
        let principalClassName: String

        // These are extracted off-main since they're static protocol properties
        let pluginName: String
        let pluginVersion: String
        let pluginDescription: String
        let capabilities: [PluginCapability]
        let databaseTypeId: String?
        let additionalTypeIds: [String]
        let pluginIconName: String
        let defaultPort: Int?
    }

    /// Perform the expensive bundle.load() and principalClass resolution off MainActor.
    /// Returns successfully loaded bundles with their metadata extracted.
    nonisolated private static func loadBundlesOffMain(
        _ pending: [(url: URL, source: PluginSource)]
    ) async -> [LoadedBundle] {
        var results: [LoadedBundle] = []
        for entry in pending {
            guard let bundle = Bundle(url: entry.url) else {
                logger.error("Cannot create bundle from \(entry.url.lastPathComponent)")
                continue
            }

            let infoPlist = bundle.infoDictionary ?? [:]
            let pluginKitVersion = infoPlist["TableProPluginKitVersion"] as? Int ?? 0
            if pluginKitVersion > currentPluginKitVersion {
                logger.error("Plugin \(entry.url.lastPathComponent) requires PluginKit v\(pluginKitVersion), current is v\(currentPluginKitVersion)")
                continue
            }

            if let minAppVersion = infoPlist["TableProMinAppVersion"] as? String {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                    logger.error("Plugin \(entry.url.lastPathComponent) requires app v\(minAppVersion)")
                    continue
                }
            }

            if entry.source == .userInstalled {
                if pluginKitVersion < currentPluginKitVersion {
                    logger.error("User plugin \(entry.url.lastPathComponent) has outdated PluginKit v\(pluginKitVersion)")
                    continue
                }
            }

            // Heavy I/O: dynamic linker resolution, C bridge library initialization
            guard bundle.load() else {
                logger.error("Bundle failed to load executable: \(entry.url.lastPathComponent)")
                continue
            }

            guard let principalClass = bundle.principalClass as? any TableProPlugin.Type else {
                logger.error("Principal class does not conform to TableProPlugin: \(entry.url.lastPathComponent)")
                continue
            }

            let driverType = principalClass as? any DriverPlugin.Type
            let version = readRegistryVersion(for: entry.url) ?? principalClass.pluginVersion
            let loaded = LoadedBundle(
                url: entry.url,
                source: entry.source,
                bundle: bundle,
                principalClassName: NSStringFromClass(principalClass),
                pluginName: principalClass.pluginName,
                pluginVersion: version,
                pluginDescription: principalClass.pluginDescription,
                capabilities: principalClass.capabilities,
                databaseTypeId: driverType?.databaseTypeId,
                additionalTypeIds: driverType?.additionalDatabaseTypeIds ?? [],
                pluginIconName: driverType?.iconName ?? "puzzlepiece",
                defaultPort: driverType?.defaultPort
            )
            results.append(loaded)
        }
        return results
    }

    /// Register pre-loaded bundles into the plugin dictionaries. Must be called on MainActor.
    private func registerLoadedPlugins(_ loaded: [LoadedBundle]) {
        let disabled = disabledPluginIds

        for item in loaded {
            let bundleId = item.bundle.bundleIdentifier ?? item.url.lastPathComponent
            let entry = PluginEntry(
                id: bundleId,
                bundle: item.bundle,
                url: item.url,
                source: item.source,
                name: item.pluginName,
                version: item.pluginVersion,
                pluginDescription: item.pluginDescription,
                capabilities: item.capabilities,
                isEnabled: !disabled.contains(bundleId),
                databaseTypeId: item.databaseTypeId,
                additionalTypeIds: item.additionalTypeIds,
                pluginIconName: item.pluginIconName,
                defaultPort: item.defaultPort
            )

            plugins.append(entry)

            if let principalClass = item.bundle.principalClass as? any TableProPlugin.Type {
                validateCapabilityDeclarations(principalClass, pluginId: bundleId)
                if entry.isEnabled {
                    let instance = principalClass.init()
                    registerCapabilities(instance, pluginId: bundleId)
                }
            }

            Self.logger.info("Loaded plugin '\(entry.name)' v\(entry.version) [\(item.source == .builtIn ? "built-in" : "user")]")
        }

        queryBuildingDriverCache.removeAll()
    }

    private func discoverAllPlugins() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: userPluginsDir.path) {
            do {
                try fm.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create user plugins directory: \(error.localizedDescription)")
            }
        }

        if let builtInDir = builtInPluginsDir {
            discoverPlugins(from: builtInDir, source: .builtIn)
        }

        discoverPlugins(from: userPluginsDir, source: .userInstalled)

        Self.logger.info("Discovered \(self.pendingPluginURLs.count) plugin(s), will load on first use")
    }

    /// Load all discovered but not-yet-loaded plugin bundles synchronously on MainActor.
    /// Only used by install/uninstall paths that need immediate plugin availability.
    /// Normal startup uses `loadPlugins()` which loads bundles off the main thread.
    func loadPendingPlugins(clearRestartFlag: Bool = false) {
        if clearRestartFlag {
            _needsRestart = false
        }
        guard !pendingPluginURLs.isEmpty else { return }
        let pending = pendingPluginURLs
        pendingPluginURLs.removeAll()

        for entry in pending {
            do {
                try loadPlugin(at: entry.url, source: entry.source)
            } catch {
                Self.logger.error("Failed to load plugin at \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        queryBuildingDriverCache.removeAll()
        hasFinishedInitialLoad = true
        validateDependencies()
        Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s), \(self.importPlugins.count) import format(s)")
    }

    private func discoverPlugins(from directory: URL, source: PluginSource) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for itemURL in contents where itemURL.pathExtension == "tableplugin" {
            do {
                try discoverPlugin(at: itemURL, source: source)
            } catch {
                Self.logger.error("Failed to discover plugin at \(itemURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func discoverPlugin(at url: URL, source: PluginSource) throws {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        let infoPlist = bundle.infoDictionary ?? [:]

        let pluginKitVersion = infoPlist["TableProPluginKitVersion"] as? Int ?? 0
        if pluginKitVersion > Self.currentPluginKitVersion {
            throw PluginError.incompatibleVersion(
                required: pluginKitVersion,
                current: Self.currentPluginKitVersion
            )
        }

        if let minAppVersion = infoPlist["TableProMinAppVersion"] as? String {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.appVersionTooOld(minimumRequired: minAppVersion, currentApp: appVersion)
            }
        }

        if source == .userInstalled {
            // User-installed plugins compiled against an older DriverPlugin protocol
            // have stale witness tables — accessing protocol properties crashes with
            // EXC_BAD_ACCESS. Reject them before loading the bundle.
            if pluginKitVersion < Self.currentPluginKitVersion {
                throw PluginError.incompatibleVersion(
                    required: Self.currentPluginKitVersion,
                    current: pluginKitVersion
                )
            }
            try verifyCodeSignature(bundle: bundle)
        }

        pendingPluginURLs.append((url: url, source: source))
    }

    @discardableResult
    private func loadPlugin(at url: URL, source: PluginSource) throws -> PluginEntry {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        let infoPlist = bundle.infoDictionary ?? [:]

        let pluginKitVersion = infoPlist["TableProPluginKitVersion"] as? Int ?? 0
        if pluginKitVersion > Self.currentPluginKitVersion {
            throw PluginError.incompatibleVersion(
                required: pluginKitVersion,
                current: Self.currentPluginKitVersion
            )
        }

        if let minAppVersion = infoPlist["TableProMinAppVersion"] as? String {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.appVersionTooOld(minimumRequired: minAppVersion, currentApp: appVersion)
            }
        }

        if source == .userInstalled {
            if pluginKitVersion < Self.currentPluginKitVersion {
                throw PluginError.incompatibleVersion(
                    required: Self.currentPluginKitVersion,
                    current: pluginKitVersion
                )
            }
            try verifyCodeSignature(bundle: bundle)
        }

        guard bundle.load() else {
            throw PluginError.invalidBundle("Bundle failed to load executable")
        }

        guard let principalClass = bundle.principalClass as? any TableProPlugin.Type else {
            throw PluginError.invalidBundle("Principal class does not conform to TableProPlugin")
        }

        let bundleId = bundle.bundleIdentifier ?? url.lastPathComponent
        let disabled = disabledPluginIds

        let driverType = principalClass as? any DriverPlugin.Type
        let version = Self.readRegistryVersion(for: url) ?? principalClass.pluginVersion
        let entry = PluginEntry(
            id: bundleId,
            bundle: bundle,
            url: url,
            source: source,
            name: principalClass.pluginName,
            version: version,
            pluginDescription: principalClass.pluginDescription,
            capabilities: principalClass.capabilities,
            isEnabled: !disabled.contains(bundleId),
            databaseTypeId: driverType?.databaseTypeId,
            additionalTypeIds: driverType?.additionalDatabaseTypeIds ?? [],
            pluginIconName: driverType?.iconName ?? "puzzlepiece",
            defaultPort: driverType?.defaultPort
        )

        plugins.append(entry)
        validateCapabilityDeclarations(principalClass, pluginId: bundleId)

        if entry.isEnabled {
            let instance = principalClass.init()
            registerCapabilities(instance, pluginId: bundleId)
        }

        Self.logger.info("Loaded plugin '\(entry.name)' v\(entry.version) [\(source == .builtIn ? "built-in" : "user")]")

        return entry
    }

    // MARK: - Capability Registration

    private func registerCapabilities(_ instance: any TableProPlugin, pluginId: String) {
        let declared = Set(type(of: instance).capabilities)
        var registeredAny = false

        if let driver = instance as? any DriverPlugin {
            if !declared.contains(.databaseDriver) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to DriverPlugin but does not declare .databaseDriver capability — registering anyway")
            }
            do {
                try validateDriverDescriptor(type(of: driver), pluginId: pluginId)
            } catch {
                Self.logger.error("Plugin '\(pluginId)' driver rejected: \(error.localizedDescription)")
                return
            }
            if !driverPlugins.keys.contains(type(of: driver).databaseTypeId) {
                let driverType = type(of: driver)
                let typeId = driverType.databaseTypeId
                driverPlugins[typeId] = driver
                for additionalId in driverType.additionalDatabaseTypeIds {
                    driverPlugins[additionalId] = driver
                }

                // Self-register plugin metadata from the DriverPlugin protocol.
                let snapshot = PluginMetadataRegistry.shared.buildMetadataSnapshot(
                    from: driverType,
                    isDownloadable: driverType.isDownloadable
                )
                PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId, preserveIcon: true)
                for additionalId in driverType.additionalDatabaseTypeIds {
                    PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: additionalId, preserveIcon: true)
                    PluginMetadataRegistry.shared.registerTypeAlias(additionalId, primaryTypeId: typeId)
                }

                Self.logger.debug("Registered driver plugin '\(pluginId)' for database type '\(typeId)'")
                registeredAny = true
            }
        }

        if let exportPlugin = instance as? any ExportFormatPlugin {
            if !declared.contains(.exportFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ExportFormatPlugin but does not declare .exportFormat capability — registering anyway")
            }
            let formatId = type(of: exportPlugin).formatId
            exportPlugins[formatId] = exportPlugin
            Self.logger.debug("Registered export plugin '\(pluginId)' for format '\(formatId)'")
            registeredAny = true
        }

        if let importPlugin = instance as? any ImportFormatPlugin {
            if !declared.contains(.importFormat) {
                Self.logger.warning("Plugin '\(pluginId)' conforms to ImportFormatPlugin but does not declare .importFormat capability — registering anyway")
            }
            let formatId = type(of: importPlugin).formatId
            importPlugins[formatId] = importPlugin
            Self.logger.debug("Registered import plugin '\(pluginId)' for format '\(formatId)'")
            registeredAny = true
        }

        if registeredAny {
            pluginInstances[pluginId] = instance
        }
    }

    private func validateCapabilityDeclarations(_ pluginType: any TableProPlugin.Type, pluginId: String) {
        let declared = Set(pluginType.capabilities)
        let isDriver = pluginType is any DriverPlugin.Type
        let isExporter = pluginType is any ExportFormatPlugin.Type
        let isImporter = pluginType is any ImportFormatPlugin.Type

        if declared.contains(.databaseDriver) && !isDriver {
            Self.logger.warning("Plugin '\(pluginId)' declares .databaseDriver but does not conform to DriverPlugin")
        }
        if declared.contains(.exportFormat) && !isExporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .exportFormat but does not conform to ExportFormatPlugin")
        }
        if declared.contains(.importFormat) && !isImporter {
            Self.logger.warning("Plugin '\(pluginId)' declares .importFormat but does not conform to ImportFormatPlugin")
        }
    }

    // MARK: - Descriptor Validation

    /// Reject-level validation: runs synchronously before registration.
    /// Checks only properties already accessed during the loading flow.
    func validateDriverDescriptor(_ driverType: any DriverPlugin.Type, pluginId: String) throws {
        guard !driverType.databaseTypeId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidDescriptor(pluginId: pluginId, reason: "databaseTypeId is empty")
        }

        guard !driverType.databaseDisplayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidDescriptor(pluginId: pluginId, reason: "databaseDisplayName is empty")
        }

        let typeId = driverType.databaseTypeId
        if driverPlugins[typeId] != nil {
            let existingName = PluginMetadataRegistry.shared
                .snapshot(forTypeId: typeId)?.displayName ?? typeId
            throw PluginError.invalidDescriptor(
                pluginId: pluginId,
                reason: "databaseTypeId '\(typeId)' is already registered by '\(existingName)'"
            )
        }

        let allAdditionalIds = driverType.additionalDatabaseTypeIds
        if allAdditionalIds.contains(typeId) {
            Self.logger.warning("Plugin '\(pluginId)': additionalDatabaseTypeIds contains the primary databaseTypeId '\(typeId)'")
        }

        for additionalId in allAdditionalIds {
            if driverPlugins[additionalId] != nil {
                let existingName = PluginMetadataRegistry.shared
                    .snapshot(forTypeId: additionalId)?.displayName ?? additionalId
                throw PluginError.invalidDescriptor(
                    pluginId: pluginId,
                    reason: "additionalDatabaseTypeId '\(additionalId)' is already registered by '\(existingName)'"
                )
            }
        }
    }

    /// Warn-level connection field validation. Called lazily on first access via
    /// `additionalConnectionFields(for:)`, not during plugin loading (protocol witness
    /// tables may be unstable for dynamically loaded bundles during the loading path).
    func validateConnectionFields(_ fields: [ConnectionField], pluginId: String) {
        var seenIds = Set<String>()
        for field in fields {
            if field.id.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field has empty id")
            }
            if field.label.trimmingCharacters(in: .whitespaces).isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field '\(field.id)' has empty label")
            }
            if !seenIds.insert(field.id).inserted {
                Self.logger.warning("Plugin '\(pluginId)': duplicate connection field id '\(field.id)'")
            }
            if case .dropdown(let options) = field.fieldType, options.isEmpty {
                Self.logger.warning("Plugin '\(pluginId)': connection field '\(field.id)' is a dropdown with no options")
            }
        }
    }

    private func validateDialectDescriptor(_ dialect: SQLDialectDescriptor, pluginId: String) {
        if dialect.identifierQuote.trimmingCharacters(in: .whitespaces).isEmpty {
            Self.logger.warning("Plugin '\(pluginId)': sqlDialect.identifierQuote is empty")
        }
        if dialect.keywords.isEmpty {
            Self.logger.warning("Plugin '\(pluginId)': sqlDialect.keywords is empty")
        }
    }

    private func replaceExistingPlugin(bundleId: String) {
        guard let existingIndex = plugins.firstIndex(where: { $0.id == bundleId }) else { return }
        // Order matters: unregisterCapabilities reads from `plugins` to find the principal class
        unregisterCapabilities(pluginId: bundleId)
        plugins[existingIndex].bundle.unload()
        plugins.remove(at: existingIndex)
    }

    private func unregisterCapabilities(pluginId: String) {
        pluginInstances.removeValue(forKey: pluginId)

        guard let entry = plugins.first(where: { $0.id == pluginId }) else { return }

        if let typeId = entry.databaseTypeId {
            PluginMetadataRegistry.shared.unregister(typeId: typeId)
            for additionalId in entry.additionalTypeIds {
                PluginMetadataRegistry.shared.unregister(typeId: additionalId)
            }

            let allTypeIds = Set([typeId] + entry.additionalTypeIds)
            driverPlugins = driverPlugins.filter { key, _ in
                !allTypeIds.contains(key)
            }
        }

        if let exportClass = entry.bundle.principalClass as? any ExportFormatPlugin.Type {
            let formatId = exportClass.formatId
            exportPlugins = exportPlugins.filter { key, _ in key != formatId }
        }

        if let importClass = entry.bundle.principalClass as? any ImportFormatPlugin.Type {
            let formatId = importClass.formatId
            importPlugins = importPlugins.filter { key, _ in key != formatId }
        }
    }

    // MARK: - Available Database Types

    /// All database types with loaded plugins, ordered by display name.
    var availableDatabaseTypes: [DatabaseType] {
        var types: [DatabaseType] = []
        for entry in plugins where entry.isEnabled {
            if let typeId = entry.databaseTypeId {
                types.append(DatabaseType(rawValue: typeId))
            }
            for additionalId in entry.additionalTypeIds {
                types.append(DatabaseType(rawValue: additionalId))
            }
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Driver Availability

    func isDriverAvailable(for databaseType: DatabaseType) -> Bool {
        driverPlugins[databaseType.pluginTypeId] != nil
    }

    func isDriverLoaded(for databaseType: DatabaseType) -> Bool {
        driverPlugins[databaseType.pluginTypeId] != nil
    }

    func sqlDialect(for databaseType: DatabaseType) -> SQLDialectDescriptor? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.sqlDialect
    }

    func statementCompletions(for databaseType: DatabaseType) -> [CompletionEntry] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.statementCompletions ?? []
    }

    func additionalConnectionFields(for databaseType: DatabaseType) -> [ConnectionField] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connection.additionalConnectionFields ?? []
    }

    // MARK: - Plugin Property Lookups

    func driverPlugin(for databaseType: DatabaseType) -> (any DriverPlugin)? {
        driverPlugins[databaseType.pluginTypeId]
    }

    /// Returns a temporary plugin driver for query building (buildBrowseQuery), or nil
    /// if the plugin doesn't implement custom query building (NoSQL hooks).
    func queryBuildingDriver(for databaseType: DatabaseType) -> (any PluginDatabaseDriver)? {
        let typeId = databaseType.pluginTypeId
        if let cached = queryBuildingDriverCache[typeId] { return cached }
        guard let plugin = driverPlugin(for: databaseType) else {
            if hasFinishedInitialLoad {
                queryBuildingDriverCache[typeId] = .some(nil)
            }
            return nil
        }
        let config = DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: "")
        let driver = plugin.createDriver(config: config)
        let result: (any PluginDatabaseDriver)? =
            driver.buildBrowseQuery(table: "_probe", sortColumns: [], columns: [], limit: 1, offset: 0) != nil
            ? driver : nil
        if hasFinishedInitialLoad {
            queryBuildingDriverCache[typeId] = .some(result)
        }
        return result
    }

    func editorLanguage(for databaseType: DatabaseType) -> EditorLanguage {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editorLanguage ?? .sql
    }

    func queryLanguageName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .queryLanguageName ?? "SQL"
    }

    func connectionMode(for databaseType: DatabaseType) -> ConnectionMode {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .connectionMode ?? .network
    }

    func brandColor(for databaseType: DatabaseType) -> Color {
        if let hex = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?.brandColorHex {
            return Color(hex: hex)
        }
        return Color.gray
    }

    func supportsDatabaseSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .supportsDatabaseSwitching ?? true
    }

    func supportsSchemaSwitching(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSchemaSwitching ?? false
    }

    func supportsImport(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsImport ?? true
    }

    func systemDatabaseNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.systemDatabaseNames ?? []
    }

    func systemSchemaNames(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.systemSchemaNames ?? []
    }

    func columnTypesByCategory(for databaseType: DatabaseType) -> [String: [String]] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .editor.columnTypesByCategory ?? PluginMetadataSnapshot.EditorConfig.defaults.columnTypesByCategory
    }

    func requiresAuthentication(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .requiresAuthentication ?? true
    }

    func fileExtensions(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.fileExtensions ?? []
    }

    func tableEntityName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.tableEntityName ?? "Tables"
    }

    func supportsCascadeDrop(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsCascadeDrop ?? false
    }

    func supportsForeignKeyDisable(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsForeignKeyDisable ?? true
    }

    func immutableColumns(for databaseType: DatabaseType) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.immutableColumns ?? []
    }

    func supportsReadOnlyMode(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsReadOnlyMode ?? true
    }

    func defaultSchemaName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.defaultSchemaName ?? "public"
    }

    func requiresReconnectForDatabaseSwitch(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.requiresReconnectForDatabaseSwitch ?? false
    }

    func structureColumnFields(for databaseType: DatabaseType) -> [StructureColumnField] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.structureColumnFields ?? [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
    }

    func defaultPrimaryKeyColumn(for databaseType: DatabaseType) -> String? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.defaultPrimaryKeyColumn
    }

    func supportsQueryProgress(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsQueryProgress ?? false
    }

    func supportsSSH(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSSH ?? true
    }

    func supportsSSL(for databaseType: DatabaseType) -> Bool {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .capabilities.supportsSSL ?? true
    }

    func autoLimitStyle(for databaseType: DatabaseType) -> AutoLimitStyle {
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId) else {
            return .limit
        }
        guard let dialect = snapshot.editor.sqlDialect else { return .none }
        return dialect.autoLimitStyle
    }

    func paginationStyle(for databaseType: DatabaseType) -> SQLDialectDescriptor.PaginationStyle {
        sqlDialect(for: databaseType)?.paginationStyle ?? .limit
    }

    func offsetFetchOrderBy(for databaseType: DatabaseType) -> String {
        sqlDialect(for: databaseType)?.offsetFetchOrderBy ?? "ORDER BY (SELECT NULL)"
    }

    func databaseGroupingStrategy(for databaseType: DatabaseType) -> GroupingStrategy {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.databaseGroupingStrategy ?? .byDatabase
    }

    func defaultGroupName(for databaseType: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?
            .schema.defaultGroupName ?? "main"
    }

    var allRegisteredFileExtensions: [String: DatabaseType] {
        let extMap = PluginMetadataRegistry.shared.allFileExtensions()
        var result: [String: DatabaseType] = [:]
        for (ext, typeId) in extMap {
            result[ext] = DatabaseType(rawValue: typeId)
        }
        return result
    }

    var allRegisteredURLSchemes: Set<String> {
        Set(PluginMetadataRegistry.shared.allUrlSchemes().keys)
    }

    func installMissingPlugin(
        for databaseType: DatabaseType,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let pluginTypeId = databaseType.pluginTypeId

        if let existingEntry = plugins.first(where: { entry in
            entry.databaseTypeId == pluginTypeId || entry.additionalTypeIds.contains(pluginTypeId)
        }) {
            if !existingEntry.isEnabled {
                setEnabled(true, pluginId: existingEntry.id)
                loadPendingPlugins()
            }
            if driverPlugins[pluginTypeId] != nil {
                Self.logger.info("Re-enabled existing plugin '\(existingEntry.name)' for '\(databaseType.rawValue)'")
                return
            }
            Self.logger.warning("Plugin '\(existingEntry.id)' exists but driver not registered, reinstalling")
            if existingEntry.source == .userInstalled {
                try? uninstallPlugin(id: existingEntry.id)
            }
        }

        let registryClient = RegistryClient.shared
        await registryClient.fetchManifest()

        guard let manifest = registryClient.manifest else {
            throw PluginError.downloadFailed(String(localized: "Could not fetch plugin registry"))
        }

        guard let registryPlugin = manifest.plugins.first(where: { plugin in
            plugin.databaseTypeIds?.contains(pluginTypeId) == true
        }) else {
            throw PluginError.notFound
        }

        let entry = try await installFromRegistry(registryPlugin, progress: progress)
        Self.logger.info("Installed missing plugin '\(entry.name)' for database type '\(databaseType.rawValue)'")
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool, pluginId: String) {
        guard let index = plugins.firstIndex(where: { $0.id == pluginId }) else { return }

        plugins[index].isEnabled = enabled

        var disabled = disabledPluginIds
        if enabled {
            disabled.remove(pluginId)
        } else {
            disabled.insert(pluginId)
        }
        disabledPluginIds = disabled

        if enabled {
            if let principalClass = plugins[index].bundle.principalClass as? any TableProPlugin.Type {
                let instance = principalClass.init()
                registerCapabilities(instance, pluginId: pluginId)
            }
        } else {
            unregisterCapabilities(pluginId: pluginId)
        }

        queryBuildingDriverCache.removeAll()
        Self.logger.info("Plugin '\(pluginId)' \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Install / Uninstall

    func installPlugin(from url: URL) async throws -> PluginEntry {
        guard !isInstalling else {
            throw PluginError.installFailed("Another plugin installation is already in progress")
        }
        isInstalling = true
        defer { isInstalling = false }

        if url.pathExtension == "tableplugin" {
            return try installBundle(from: url)
        } else {
            return try await installFromZip(from: url)
        }
    }

    private func installBundle(from url: URL) throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try verifyCodeSignature(bundle: sourceBundle)

        let newBundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent
        if let existing = plugins.first(where: { $0.id == newBundleId }), existing.source == .builtIn {
            throw PluginError.pluginConflict(existingName: existing.name)
        }

        replaceExistingPlugin(bundleId: newBundleId)

        let fm = FileManager.default
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)

        if url.standardizedFileURL != destURL.standardizedFileURL {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
        }

        let entry = try loadPlugin(at: destURL, source: .userInstalled)

        Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
        return entry
    }

    private func installFromZip(from url: URL) async throws -> PluginEntry {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", url.path, tempDir.path]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PluginError.installFailed(
                        "Failed to extract archive (ditto exit code \(proc.terminationStatus))"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let extractedBundles = try fm.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "tableplugin" }

        guard !extractedBundles.isEmpty else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }

        var lastEntry: PluginEntry?
        for extracted in extractedBundles {
            guard let extractedBundle = Bundle(url: extracted) else {
                throw PluginError.invalidBundle("Cannot create bundle from extracted plugin '\(extracted.lastPathComponent)'")
            }

            try verifyCodeSignature(bundle: extractedBundle)

            let newBundleId = extractedBundle.bundleIdentifier ?? extracted.lastPathComponent
            if let existing = plugins.first(where: { $0.id == newBundleId }), existing.source == .builtIn {
                throw PluginError.pluginConflict(existingName: existing.name)
            }

            replaceExistingPlugin(bundleId: newBundleId)

            let destURL = userPluginsDir.appendingPathComponent(extracted.lastPathComponent)

            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: extracted, to: destURL)

            let entry = try loadPlugin(at: destURL, source: .userInstalled)
            Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
            lastEntry = entry
        }

        guard let entry = lastEntry else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }
        return entry
    }

    func uninstallPlugin(id: String) throws {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw PluginError.notFound
        }

        let entry = plugins[index]

        guard entry.source == .userInstalled else {
            throw PluginError.cannotUninstallBuiltIn
        }

        unregisterCapabilities(pluginId: id)
        entry.bundle.unload()
        plugins.remove(at: index)

        removeRegistryMetadata(for: entry.url)

        let fm = FileManager.default
        if fm.fileExists(atPath: entry.url.path) {
            try fm.removeItem(at: entry.url)
        }

        PluginSettingsStorage(pluginId: id).removeAll()

        var disabled = disabledPluginIds
        disabled.remove(id)
        disabledPluginIds = disabled

        queryBuildingDriverCache.removeAll()

        Self.logger.info("Uninstalled plugin '\(id)'")
        _needsRestart = true
    }

    // MARK: - Dependency Validation

    private func validateDependencies() {
        let loadedIds = Set(plugins.map(\.id))
        for plugin in plugins where plugin.isEnabled {
            guard let principalClass = plugin.bundle.principalClass as? any TableProPlugin.Type else { continue }
            let deps = principalClass.dependencies
            for dep in deps {
                if !loadedIds.contains(dep) {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is not installed")
                } else if let depEntry = plugins.first(where: { $0.id == dep }), !depEntry.isEnabled {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is disabled")
                }
            }
        }
    }

    // MARK: - Code Signature Verification

    private static let signingTeamId = "D7HJ5TFYCU"

    private func createSigningRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.signingTeamId)\"" as CFString
        SecRequirementCreateWithString(requirementString, SecCSFlags(), &requirement)
        return requirement
    }

    private func verifyCodeSignature(bundle: Bundle) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )

        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(createStatus)
            )
        }

        let requirement = createSigningRequirement()

        let checkStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )

        guard checkStatus == errSecSuccess else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(checkStatus)
            )
        }
    }

    private static func describeOSStatus(_ status: OSStatus) -> String {
        switch status {
        case -67_062: return "bundle is not signed"
        case -67_061: return "code signature is invalid"
        case -67_030: return "code signature has been modified or corrupted"
        case -67_013: return "signing certificate has expired"
        case -67_058: return "code signature is missing required fields"
        case -67_028: return "resource envelope has been modified"
        default: return "verification failed (OSStatus \(status))"
        }
    }
}
