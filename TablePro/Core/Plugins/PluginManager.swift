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
                let pending = initialLoadWaiters
                initialLoadWaiters.removeAll()
                for waiter in pending {
                    waiter.continuation.resume()
                }
            }
        }
    }

    @ObservationIgnored private var initialLoadWaiters: [LoadWaiter] = []

    private struct LoadWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    func waitForInitialLoad() async {
        if hasFinishedInitialLoad { return }
        let waiterId = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.resumeWaiter(id: waiterId)
        }
        defer { timeoutTask.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if hasFinishedInitialLoad {
                continuation.resume()
                return
            }
            initialLoadWaiters.append(LoadWaiter(id: waiterId, continuation: continuation))
        }
    }

    private func resumeWaiter(id: UUID) {
        guard let index = initialLoadWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = initialLoadWaiters.remove(at: index)
        waiter.continuation.resume()
    }

    internal(set) var rejectedPlugins: [RejectedPlugin] = []

    var needsRestart: Bool = false

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
        Self.clearLegacyNeedsRestartKey(in: userDefaults)
    }

    nonisolated private static func clearLegacyNeedsRestartKey(in defaults: UserDefaults) {
        let legacyKey = "com.TablePro.needsRestart"
        if defaults.object(forKey: legacyKey) != nil {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    nonisolated static func defaultUserPluginsDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TablePro/Plugins", isDirectory: true)
    }

    // MARK: - Registry Metadata

    private struct RegistryMetadata: Codable {
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

    nonisolated static func bundleVersion(at pluginURL: URL) -> String? {
        guard let bundle = Bundle(url: pluginURL),
              let info = bundle.infoDictionary
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    func saveRegistryMetadata(pluginId: String, pluginURL: URL) {
        let metadata = RegistryMetadata(pluginId: pluginId)
        let url = Self.metadataURL(for: pluginURL)
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save registry metadata for \(pluginId): \(error.localizedDescription)")
        }
    }

    func removeRegistryMetadata(for pluginURL: URL) {
        let url = Self.metadataURL(for: pluginURL)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone, nothing to log.
        } catch {
            Self.logger.error("Failed to remove registry metadata at \(url.lastPathComponent): \(error.localizedDescription)")
        }
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
                if entry.source == .userInstalled, let bundleId = Bundle(url: entry.url)?.bundleIdentifier {
                    Self.logger.warning("Plugin '\(bundleId)' declared no TableProProvides* capability keys in Info.plist; eager loading will block startup. Add TableProProvidesDatabaseTypeIds / ExportFormatIds / ImportFormatIds for lazy load.")
                }
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
            self.needsRestart = false
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
        let version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
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
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
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

        var candidates: [PluginCandidate] = []
        if let builtInDir = builtInPluginsURL {
            candidates += Self.collectCandidates(in: builtInDir, source: .builtIn)
        }
        candidates += Self.collectCandidates(in: userPluginsDir, source: .userInstalled)

        let winners = Self.selectWinners(candidates: candidates)
        pruneOutdatedUserCopies(candidates: candidates, winners: winners)

        for winner in winners.values {
            do {
                try discoverPlugin(at: winner.url, source: winner.source)
            } catch {
                Self.logger.error("Failed to discover plugin at \(winner.url.lastPathComponent): \(error.localizedDescription)")
                if winner.source == .userInstalled {
                    let bundle = Bundle(url: winner.url)
                    rejectedPlugins.append(RejectedPlugin(
                        url: winner.url,
                        bundleId: bundle?.bundleIdentifier,
                        registryId: Self.readRegistryMetadata(for: winner.url)?.pluginId,
                        name: winner.url.deletingPathExtension().lastPathComponent,
                        reason: error.localizedDescription,
                        isOutdated: (error as? PluginError)?.isOutdated ?? false
                    ))
                }
            }
        }

        Self.logger.info("Discovered \(self.pendingPluginURLs.count) plugin(s), will load on first use")
    }

    private struct PluginCandidate {
        let url: URL
        let source: PluginSource
        let bundleId: String
        let version: String
    }

    nonisolated private static func collectCandidates(
        in directory: URL,
        source: PluginSource
    ) -> [PluginCandidate] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [PluginCandidate] = []
        for itemURL in contents where itemURL.pathExtension == "tableplugin" {
            guard let bundle = Bundle(url: itemURL),
                  let bundleId = bundle.bundleIdentifier
            else { continue }
            let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
            results.append(PluginCandidate(url: itemURL, source: source, bundleId: bundleId, version: version))
        }
        return results
    }

    nonisolated private static func selectWinners(
        candidates: [PluginCandidate]
    ) -> [String: PluginCandidate] {
        var winners: [String: PluginCandidate] = [:]
        for candidate in candidates {
            guard let existing = winners[candidate.bundleId] else {
                winners[candidate.bundleId] = candidate
                continue
            }
            let order = candidate.version.compare(existing.version, options: .numeric)
            let candidateWins = order == .orderedDescending
                || (order == .orderedSame && candidate.source == .builtIn)
            if candidateWins {
                winners[candidate.bundleId] = candidate
            }
        }
        return winners
    }

    private func pruneOutdatedUserCopies(
        candidates: [PluginCandidate],
        winners: [String: PluginCandidate]
    ) {
        let fm = FileManager.default
        for candidate in candidates where candidate.source == .userInstalled {
            guard let winner = winners[candidate.bundleId], winner.url != candidate.url else { continue }
            do {
                try fm.removeItem(at: candidate.url)
                Self.removeRegistryMetadataFile(for: candidate.url)
                let order = candidate.version.compare(winner.version, options: .numeric)
                let reason = order == .orderedSame ? "equal version" : "older version"
                Self.logger.info(
                    "Pruned user-installed '\(candidate.bundleId)' v\(candidate.version) (\(reason); \(winner.source == .builtIn ? "built-in" : "winning") v\(winner.version) takes precedence)"
                )
            } catch {
                Self.logger.warning(
                    "Failed to prune user copy '\(candidate.bundleId)' at \(candidate.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    nonisolated private static func removeRegistryMetadataFile(for pluginURL: URL) {
        let url = metadataURL(for: pluginURL)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.warning("Failed to remove metadata sidecar at \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func loadPendingPluginsAsync(clearRestartFlag: Bool = false) async {
        if clearRestartFlag {
            needsRestart = false
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
            needsRestart = false
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

    @discardableResult
    func loadPluginAsync(at url: URL, source: PluginSource) async throws -> PluginEntry {
        if source == .userInstalled {
            guard let bundle = Bundle(url: url) else {
                throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
            }
            try verifyCodeSignature(bundle: bundle)
        }

        let loaded = try await Self.validateAndLoadBundleAsync(at: url, source: source)

        guard let entry = registerBundle(loaded, url: url, source: source) else {
            throw PluginError.invalidBundle("Principal class does not conform to TableProPlugin")
        }

        return entry
    }

    nonisolated private static func validateAndLoadBundleAsync(
        at url: URL,
        source: PluginSource
    ) async throws -> Bundle {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let bundle = try validateAndLoadBundle(at: url, source: source)
                    continuation.resume(returning: bundle)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
