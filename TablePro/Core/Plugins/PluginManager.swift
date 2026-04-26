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
    static let currentPluginKitVersion = 7
    private static let disabledPluginsKey = "com.TablePro.disabledPlugins"
    private static let legacyDisabledPluginsKey = "disabledPlugins"

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

    internal(set) var rejectedPlugins: [(name: String, reason: String)] = []

    private static let needsRestartKey = "com.TablePro.needsRestart"

    var needsRestartStorage: Bool = UserDefaults.standard.bool(
        forKey: needsRestartKey
    ) {
        didSet { UserDefaults.standard.set(needsRestartStorage, forKey: Self.needsRestartKey) }
    }

    var needsRestart: Bool { needsRestartStorage }

    internal(set) var driverPlugins: [String: any DriverPlugin] = [:]

    internal(set) var exportPlugins: [String: any ExportFormatPlugin] = [:]

    internal(set) var importPlugins: [String: any ImportFormatPlugin] = [:]

    internal(set) var pluginInstances: [String: any TableProPlugin] = [:]

    private var builtInPluginsDir: URL? { Bundle.main.builtInPlugInsURL }

    var userPluginsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    var disabledPluginIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledPluginsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.disabledPluginsKey) }
    }

    static let logger = Logger(subsystem: "com.TablePro", category: "PluginManager")

    private var pendingPluginURLs: [(url: URL, source: PluginSource)] = []

    var queryBuildingDriverCache: [String: (any PluginDatabaseDriver)?] = [:]

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

    func removeRegistryMetadata(for pluginURL: URL) {
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

    func loadPlugins() {
        migrateDisabledPluginsKey()
        discoverAllPlugins()
        let pending = pendingPluginURLs
        Task {
            let validated = await Self.validateAndLoadBundles(pending)
            self.pendingPluginURLs.removeAll()
            self.needsRestartStorage = false
            self.registerValidatedBundles(validated)
            self.validateDependencies()
            self.hasFinishedInitialLoad = true
            Self.logger.info("Loaded \(self.plugins.count) plugin(s): \(self.driverPlugins.count) driver(s), \(self.exportPlugins.count) export format(s), \(self.importPlugins.count) import format(s)")
            if !self.rejectedPlugins.isEmpty {
                NotificationCenter.default.post(name: .pluginsRejected, object: self.rejectedPlugins)
            }
        }
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

        if source == .userInstalled {
            if pluginKitVersion < currentPluginKitVersion {
                throw PluginError.pluginOutdated(
                    pluginVersion: pluginKitVersion,
                    requiredVersion: currentPluginKitVersion
                )
            }
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

        if let builtInDir = builtInPluginsDir {
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
                    rejectedPlugins.append((
                        name: itemURL.deletingPathExtension().lastPathComponent,
                        reason: error.localizedDescription
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
