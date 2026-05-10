//
//  PluginManager.swift
//  TablePro
//

import Combine
import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

@MainActor @Observable
final class PluginManager {
    static let shared = PluginManager()
    static let currentPluginKitVersion = 11
    private static let disabledPluginsKey = "com.TablePro.disabledPlugins"
    private static let legacyDisabledPluginsKey = "disabledPlugins"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let builtInPluginsURL: URL?
    @ObservationIgnored internal let userPluginsDir: URL

    internal(set) var plugins: [PluginEntry] = []

    internal(set) var isInstalling = false

    internal(set) var hasFinishedInitialLoad = false {
        didSet {
            if hasFinishedInitialLoad {
                for continuation in initialLoadWaiters {
                    continuation.resume()
                }
                initialLoadWaiters.removeAll()
            }
        }
    }

    private var initialLoadWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForInitialLoad() async {
        if hasFinishedInitialLoad { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if self.hasFinishedInitialLoad {
                        continuation.resume()
                    } else {
                        self.initialLoadWaiters.append(continuation)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
            }
            await group.next()
            group.cancelAll()
        }
    }

    internal(set) var rejectedPlugins: [RejectedPlugin] = []

    private static let needsRestartKey = "com.TablePro.needsRestart"

    var needsRestartStorage: Bool {
        didSet { defaults.set(needsRestartStorage, forKey: Self.needsRestartKey) }
    }

    var needsRestart: Bool { needsRestartStorage }

    internal(set) var driverPlugins: [String: any DriverPlugin] = [:]

    internal(set) var exportPlugins: [String: any ExportFormatPlugin] = [:]

    internal(set) var importPlugins: [String: any ImportFormatPlugin] = [:]

    internal(set) var pluginInstances: [String: any TableProPlugin] = [:]

    var disabledPluginIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.disabledPluginsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.disabledPluginsKey) }
    }

    static let logger = Logger(subsystem: "com.TablePro", category: "PluginManager")

    private var pendingPluginURLs: [(url: URL, source: PluginSource)] = []

    @ObservationIgnored private(set) var lazyDriverURLs: [String: URL] = [:]
    @ObservationIgnored private var lazyExportURLs: [String: URL] = [:]
    @ObservationIgnored private var lazyImportURLs: [String: URL] = [:]
    @ObservationIgnored private var activatedBundleIds: Set<String> = []

    var queryBuildingDriverCache: [String: (any PluginDatabaseDriver)?] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        builtInPluginsURL: URL? = Bundle.main.builtInPlugInsURL,
        userPluginsDir: URL = PluginManager.defaultUserPluginsDir()
    ) {
        self.defaults = userDefaults
        self.builtInPluginsURL = builtInPluginsURL
        self.userPluginsDir = userPluginsDir
        self.needsRestartStorage = userDefaults.bool(forKey: Self.needsRestartKey)
    }

    nonisolated static func defaultUserPluginsDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    // MARK: - Registry Metadata

    private struct RegistryMetadata: Codable {
        let version: String
        let pluginId: String
    }

    nonisolated private static func metadataURL(for pluginURL: URL) -> URL {
        pluginURL.deletingLastPathComponent()
            .appendingPathComponent(pluginURL.lastPathComponent + ".metadata.json")
    }

    nonisolated private static func readRegistryMetadata(for pluginURL: URL) -> RegistryMetadata? {
        let url = metadataURL(for: pluginURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryMetadata.self, from: data)
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

    func removeRegistryMetadata(for pluginURL: URL) {
        let url = Self.metadataURL(for: pluginURL)
        try? FileManager.default.removeItem(at: url)
    }

    private func migrateDisabledPluginsKey() {
        if let legacy = defaults.stringArray(forKey: Self.legacyDisabledPluginsKey) {
            if defaults.stringArray(forKey: Self.disabledPluginsKey) == nil {
                defaults.set(legacy, forKey: Self.disabledPluginsKey)
            }
            defaults.removeObject(forKey: Self.legacyDisabledPluginsKey)
        }
    }

    // MARK: - Loading

    func loadPlugins() {
        migrateDisabledPluginsKey()
        discoverAllPlugins()
        var lazyPending: [(url: URL, source: PluginSource, manifest: PluginManifest)] = []
        var eagerPending: [(url: URL, source: PluginSource)] = []
        for entry in pendingPluginURLs {
            if let bundle = Bundle(url: entry.url),
               let manifest = PluginManifest(bundle: bundle),
               manifest.supportsLazyLoad {
                lazyPending.append((url: entry.url, source: entry.source, manifest: manifest))
            } else {
                eagerPending.append(entry)
            }
        }
        pendingPluginURLs.removeAll()

        for entry in lazyPending {
            registerLazyManifest(at: entry.url, source: entry.source, manifest: entry.manifest)
        }

        Task {
            if !self.rejectedPlugins.isEmpty {
                await self.autoUpdateRejectedPlugins()
            }
            let validated = await Self.validateAndLoadBundles(eagerPending)
            self.needsRestartStorage = false
            self.registerValidatedBundles(validated)
            self.validateDependencies()
            self.hasFinishedInitialLoad = true
            let lazyCount = lazyPending.count
            let eagerCount = validated.count
            Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(lazyCount) lazy + \(eagerCount) eager (\(self.driverPlugins.count) driver(s) active, \(self.exportPlugins.count) export(s) active, \(self.importPlugins.count) import(s) active)")
            if !self.rejectedPlugins.isEmpty {
                AppEvents.shared.pluginsRejected.send(self.rejectedPlugins)
            }
        }
    }

    // MARK: - Lazy Plugin Activation

    private func registerLazyManifest(at url: URL, source: PluginSource, manifest: PluginManifest) {
        guard let bundle = Bundle(url: url) else { return }
        do {
            try Self.validateBundleVersions(bundle, source: source)
        } catch {
            Self.logger.error("Lazy plugin '\(manifest.bundleId)' failed version check: \(error.localizedDescription)")
            if source == .userInstalled {
                rejectedPlugins.append(RejectedPlugin(
                    url: url,
                    bundleId: manifest.bundleId,
                    registryId: Self.readRegistryMetadata(for: url)?.pluginId,
                    name: manifest.bundleId,
                    reason: error.localizedDescription,
                    isOutdated: (error as? PluginError)?.isOutdated ?? false
                ))
            }
            return
        }
        if source == .userInstalled {
            do {
                try verifyCodeSignature(bundle: bundle)
            } catch {
                Self.logger.error("Lazy plugin '\(manifest.bundleId)' failed code-sign check: \(error.localizedDescription)")
                rejectedPlugins.append(RejectedPlugin(
                    url: url,
                    bundleId: manifest.bundleId,
                    registryId: Self.readRegistryMetadata(for: url)?.pluginId,
                    name: manifest.bundleId,
                    reason: error.localizedDescription,
                    isOutdated: false
                ))
                return
            }
        }

        let bundleId = manifest.bundleId
        if source == .userInstalled,
           let existing = plugins.first(where: { $0.id == bundleId }),
           existing.source == .builtIn
        {
            Self.logger.info("Skipping user-installed lazy '\(bundleId)': built-in version already registered")
            return
        }

        let primaryTypeId = manifest.providedDatabaseTypeIds.first
        let additionalTypeIds = Array(manifest.providedDatabaseTypeIds.dropFirst())
        let registrySnapshot = primaryTypeId.flatMap {
            PluginMetadataRegistry.shared.snapshot(forTypeId: $0)
        }

        var capabilities: [PluginCapability] = []
        if !manifest.providedDatabaseTypeIds.isEmpty { capabilities.append(.databaseDriver) }
        if !manifest.providedExportFormatIds.isEmpty { capabilities.append(.exportFormat) }
        if !manifest.providedImportFormatIds.isEmpty { capabilities.append(.importFormat) }

        let info = bundle.infoDictionary ?? [:]
        let version = Self.readRegistryMetadata(for: url)?.version
            ?? (info["CFBundleShortVersionString"] as? String)
            ?? "1.0.0"
        let displayName = registrySnapshot?.displayName
            ?? bundleId.split(separator: ".").last.map(String.init)
            ?? bundleId
        let pluginIconName = registrySnapshot?.iconName ?? "puzzlepiece"
        let defaultPort = registrySnapshot?.defaultPort
        let pluginDescription = registrySnapshot?.connection.tagline ?? ""

        let entry = PluginEntry(
            id: bundleId,
            bundle: bundle,
            url: url,
            source: source,
            name: displayName,
            version: version,
            pluginDescription: pluginDescription,
            capabilities: capabilities,
            isEnabled: !disabledPluginIds.contains(bundleId),
            databaseTypeId: primaryTypeId,
            additionalTypeIds: additionalTypeIds,
            pluginIconName: pluginIconName,
            defaultPort: defaultPort
        )
        plugins.append(entry)

        for typeId in manifest.providedDatabaseTypeIds {
            lazyDriverURLs[typeId] = url
        }
        for formatId in manifest.providedExportFormatIds {
            lazyExportURLs[formatId] = url
        }
        for formatId in manifest.providedImportFormatIds {
            lazyImportURLs[formatId] = url
        }
        Self.logger.debug("Registered lazy plugin '\(bundleId)': drivers=\(manifest.providedDatabaseTypeIds), exports=\(manifest.providedExportFormatIds), imports=\(manifest.providedImportFormatIds)")
    }

    func activateDriver(databaseTypeId typeId: String) {
        guard driverPlugins[typeId] == nil else { return }
        guard let url = lazyDriverURLs[typeId] else { return }
        activateLazyBundle(at: url)
    }

    func activateExportFormat(_ formatId: String) {
        guard exportPlugins[formatId] == nil else { return }
        guard let url = lazyExportURLs[formatId] else { return }
        activateLazyBundle(at: url)
    }

    func activateImportFormat(_ formatId: String) {
        guard importPlugins[formatId] == nil else { return }
        guard let url = lazyImportURLs[formatId] else { return }
        activateLazyBundle(at: url)
    }

    func allLazyExportFormatIds() -> [String] {
        Array(lazyExportURLs.keys)
    }

    func allLazyImportFormatIds() -> [String] {
        Array(lazyImportURLs.keys)
    }

    private func activateLazyBundle(at url: URL) {
        guard let bundle = Bundle(url: url) else { return }
        let bundleId = bundle.bundleIdentifier ?? url.lastPathComponent
        guard !activatedBundleIds.contains(bundleId) else { return }

        guard bundle.load() else {
            Self.logger.error("Failed to load lazy bundle '\(bundleId)' at \(url.lastPathComponent)")
            return
        }

        guard let principalClass = bundle.principalClass as? any TableProPlugin.Type else {
            Self.logger.error("Lazy plugin '\(bundleId)' has no TableProPlugin principal class")
            return
        }

        validateCapabilityDeclarations(principalClass, pluginId: bundleId)

        let isEnabled = plugins.first(where: { $0.id == bundleId })?.isEnabled ?? false
        if isEnabled {
            let instance = principalClass.init()
            registerCapabilities(instance, pluginId: bundleId)
        }

        activatedBundleIds.insert(bundleId)
        queryBuildingDriverCache.removeAll()
        Self.logger.info("Activated plugin '\(bundleId)' on demand")
    }

    private struct ValidatedBundle: @unchecked Sendable {
        let url: URL
        let source: PluginSource
        let bundle: Bundle
    }

    nonisolated private static func validateBundleVersions(
        _ bundle: Bundle,
        source: PluginSource
    ) throws {
        let infoPlist = bundle.infoDictionary ?? [:]
        let pluginKitVersion = infoPlist["TableProPluginKitVersion"] as? Int ?? 0

        if pluginKitVersion > currentPluginKitVersion {
            throw PluginError.incompatibleVersion(
                required: pluginKitVersion,
                current: currentPluginKitVersion
            )
        }

        if let minAppVersion = infoPlist["TableProMinAppVersion"] as? String {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.appVersionTooOld(minimumRequired: minAppVersion, currentApp: appVersion)
            }
        }

        if pluginKitVersion < currentPluginKitVersion {
            throw PluginError.pluginOutdated(
                pluginVersion: pluginKitVersion,
                requiredVersion: currentPluginKitVersion
            )
        }
    }

    nonisolated private static func validateAndLoadBundle(
        at url: URL,
        source: PluginSource
    ) throws -> Bundle {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try validateBundleVersions(bundle, source: source)

        guard bundle.load() else {
            throw PluginError.invalidBundle("Bundle failed to load executable")
        }

        return bundle
    }

    nonisolated private static func validateAndLoadBundles(
        _ pending: [(url: URL, source: PluginSource)]
    ) async -> [ValidatedBundle] {
        var results: [ValidatedBundle] = []
        for entry in pending {
            do {
                let bundle = try validateAndLoadBundle(at: entry.url, source: entry.source)
                results.append(ValidatedBundle(url: entry.url, source: entry.source, bundle: bundle))
            } catch {
                logger.error("Failed to load plugin at \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return results
    }

    private func registerBundle(_ bundle: Bundle, url: URL, source: PluginSource) -> PluginEntry? {
        guard let principalClass = bundle.principalClass as? any TableProPlugin.Type else {
            Self.logger.error("Principal class does not conform to TableProPlugin: \(url.lastPathComponent)")
            return nil
        }

        let bundleId = bundle.bundleIdentifier ?? url.lastPathComponent

        if source == .userInstalled,
           let existing = plugins.first(where: { $0.id == bundleId }),
           existing.source == .builtIn
        {
            Self.logger.info("Skipping user-installed '\(bundleId)' — built-in version already loaded")
            return existing
        }

        let rawDriverType = principalClass as? any DriverPlugin.Type
        let pluginKitVersion = bundle.infoDictionary?["TableProPluginKitVersion"] as? Int ?? 0
        if rawDriverType != nil, source == .userInstalled, pluginKitVersion != Self.currentPluginKitVersion {
            assertionFailure(
                "DriverPlugin '\(bundleId)' has TableProPluginKitVersion \(pluginKitVersion) but current is \(Self.currentPluginKitVersion); ABI mismatch would crash on static property access"
            )
            Self.logger.error("Plugin '\(bundleId)' DriverPlugin ABI mismatch: plist=\(pluginKitVersion) current=\(Self.currentPluginKitVersion). Rejecting to prevent crash.")
            rejectedPlugins.append(RejectedPlugin(
                url: url,
                bundleId: bundleId,
                registryId: Self.readRegistryMetadata(for: url)?.pluginId,
                name: principalClass.pluginName,
                reason: String(localized: "Incompatible plugin version"),
                isOutdated: pluginKitVersion < Self.currentPluginKitVersion
            ))
            return nil
        }

        let disabled = disabledPluginIds
        let driverType = rawDriverType
        let version = Self.readRegistryMetadata(for: url)?.version ?? principalClass.pluginVersion
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

    private func registerValidatedBundles(_ validated: [ValidatedBundle]) {
        for item in validated {
            _ = registerBundle(item.bundle, url: item.url, source: item.source)
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

        if let builtInDir = builtInPluginsURL {
            discoverPlugins(from: builtInDir, source: .builtIn)
            removeUserInstalledDuplicates(builtInDir: builtInDir)
        }

        discoverPlugins(from: userPluginsDir, source: .userInstalled)

        Self.logger.info("Discovered \(self.pendingPluginURLs.count) plugin(s), will load on first use")
    }

    func loadPendingPluginsAsync(clearRestartFlag: Bool = false) async {
        if clearRestartFlag {
            needsRestartStorage = false
        }
        guard !pendingPluginURLs.isEmpty else { return }
        let pending = pendingPluginURLs
        pendingPluginURLs.removeAll()

        let validated = await Self.validateAndLoadBundles(pending)
        registerValidatedBundles(validated)
        hasFinishedInitialLoad = true
        validateDependencies()
        Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s), \(self.importPlugins.count) import format(s)")
    }

    func loadPendingPlugins(clearRestartFlag: Bool = false) {
        if clearRestartFlag {
            needsRestartStorage = false
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
                if source == .userInstalled {
                    let bundle = Bundle(url: itemURL)
                    rejectedPlugins.append(RejectedPlugin(
                        url: itemURL,
                        bundleId: bundle?.bundleIdentifier,
                        registryId: Self.readRegistryMetadata(for: itemURL)?.pluginId,
                        name: itemURL.deletingPathExtension().lastPathComponent,
                        reason: error.localizedDescription,
                        isOutdated: (error as? PluginError)?.isOutdated ?? false
                    ))
                }
            }
        }
    }

    private func removeUserInstalledDuplicates(builtInDir: URL) {
        let fm = FileManager.default
        guard let builtInBundles = try? fm.contentsOfDirectory(
            at: builtInDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var builtInBundleIds = Set<String>()
        for url in builtInBundles where url.pathExtension == "tableplugin" {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                builtInBundleIds.insert(id)
            }
        }

        guard let userPlugins = try? fm.contentsOfDirectory(
            at: userPluginsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in userPlugins where url.pathExtension == "tableplugin" {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            if builtInBundleIds.contains(id) {
                do {
                    try fm.removeItem(at: url)
                    Self.logger.info("Removed user-installed '\(id)' — now ships as built-in")
                } catch {
                    Self.logger.warning("Failed to remove duplicate plugin '\(id)': \(error.localizedDescription)")
                }
            }
        }
    }

    private func discoverPlugin(at url: URL, source: PluginSource) throws {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try Self.validateBundleVersions(bundle, source: source)

        if source == .userInstalled {
            try verifyCodeSignature(bundle: bundle)
        }

        pendingPluginURLs.append((url: url, source: source))
    }

    @discardableResult
    func loadPlugin(at url: URL, source: PluginSource) throws -> PluginEntry {
        guard let bundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try Self.validateBundleVersions(bundle, source: source)

        if source == .userInstalled {
            try verifyCodeSignature(bundle: bundle)
        }

        guard bundle.load() else {
            throw PluginError.invalidBundle("Bundle failed to load executable")
        }

        guard let entry = registerBundle(bundle, url: url, source: source) else {
            throw PluginError.invalidBundle("Principal class does not conform to TableProPlugin")
        }

        return entry
    }

    func diagnose(error: Error, for type: DatabaseType) -> PluginDiagnostic? {
        guard let driver = driverPlugins[type.pluginTypeId] else { return nil }
        guard let provider = driver as? PluginDiagnosticProvider else { return nil }
        return provider.diagnose(error: error)
    }

    func replaceExistingPlugin(bundleId: String) {
        guard let existingIndex = plugins.firstIndex(where: { $0.id == bundleId }) else { return }
        unregisterCapabilities(pluginId: bundleId)
        plugins[existingIndex].bundle.unload()
        plugins.remove(at: existingIndex)
    }

    func unregisterCapabilities(pluginId: String) {
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
}
