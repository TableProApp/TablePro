import Foundation
import os

enum RegistryUpdateMode: Equatable, Sendable {
    case installNow
    case stageForNextLaunch
}

extension PluginManager {
    func installFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginEntry {
        if plugins.contains(where: { $0.id == registryPlugin.id }) {
            throw PluginError.pluginConflict(existingName: registryPlugin.name)
        }
        try reserveInstall(of: registryPlugin.id)
        defer { installsInFlight.remove(registryPlugin.id) }

        let release = try release ?? Self.newestRelease(of: registryPlugin)

        let finalURL = try await registryInstaller.install(
            registryPlugin,
            release: release,
            into: userPluginsDir,
            progress: { fraction in await progress(fraction) }
        )

        saveRegistryMetadata(pluginId: registryPlugin.id, pluginURL: finalURL)
        return try await loadPluginAsync(at: finalURL, source: .userInstalled)
    }

    // A loaded bundle cannot be unloaded and Bundle(url:) caches per path, so it updates at the next launch.
    func registryUpdateMode(forPluginId pluginId: String) -> RegistryUpdateMode {
        plugins.contains { $0.id == pluginId } ? .stageForNextLaunch : .installNow
    }

    func updateFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginUpdateOutcome {
        switch registryUpdateMode(forPluginId: registryPlugin.id) {
        case .installNow:
            let entry = try await installFromRegistry(registryPlugin, release: release, progress: progress)
            rejectedPlugins.removeAll { ($0.registryId ?? $0.bundleId) == registryPlugin.id }
            return .installed(entry)
        case .stageForNextLaunch:
            try await stageFromRegistry(registryPlugin, release: release, progress: progress)
            return .staged(pluginId: registryPlugin.id)
        }
    }

    private func stageFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease?,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard let existing = plugins.first(where: { $0.id == registryPlugin.id }) else {
            throw PluginError.notFound
        }
        guard existing.source == .userInstalled else {
            throw PluginError.pluginConflict(existingName: existing.name)
        }
        try reserveInstall(of: existing.id)
        defer { installsInFlight.remove(existing.id) }

        let release = try release ?? Self.newestRelease(of: registryPlugin)

        _ = try await registryInstaller.stage(
            registryPlugin,
            release: release,
            pluginId: existing.id,
            bundleName: existing.url.lastPathComponent,
            into: userPluginsDir,
            progress: { fraction in await progress(fraction) }
        )
        guard plugins.contains(where: { $0.id == existing.id }) else {
            removeStagedUpdate(pluginId: existing.id)
            throw PluginError.notFound
        }
        stagedPluginIds.insert(existing.id)
        PluginInstallTracker.shared.completeInstall(pluginId: existing.id)
    }

    // One install per plugin at a time: a file and a registry download would overwrite each other's copy.
    private func reserveInstall(of pluginId: String) throws {
        guard !installsInFlight.contains(pluginId) else {
            throw PluginError.installFailed(
                String(localized: "Another install is already in progress for this plugin")
            )
        }
        installsInFlight.insert(pluginId)
    }

    func installPlugin(from url: URL) async throws -> PluginEntry {
        if url.pathExtension == "tableplugin" {
            return try await installLooseBundle(from: url)
        }
        return try await installLocalZip(from: url)
    }

    func removeStagedUpdate(pluginId: String) {
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: pluginId, in: userPluginsDir)
        do {
            try FileManager.default.removeItem(at: stagedDir)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was staged.
        } catch {
            Self.logger.error("Failed to remove the staged update of '\(pluginId)': \(error.localizedDescription)")
        }
        stagedPluginIds.remove(pluginId)
    }

    nonisolated static func newestRelease(
        of registryPlugin: RegistryPlugin,
        kits: ClosedRange<Int> = compatibleKits
    ) throws -> RegistryRelease {
        try registryPlugin.newestRelease(
            channel: registryChannel,
            kits: kits,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    // MARK: - Local bundle / zip install

    // A file install drops the registry sidecar, so the update pass never replaces the file's bundle.
    private func installLooseBundle(from url: URL) async throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }
        try PluginCodeSignatureVerifier.verify(bundle: sourceBundle)
        try Self.validateBundleVersions(sourceBundle)
        let bundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent
        try reserveInstall(of: bundleId)
        defer { installsInFlight.remove(bundleId) }

        if let existing = plugins.first(where: { $0.id == bundleId }) {
            guard url.standardizedFileURL != existing.url.standardizedFileURL else { return existing }
            PluginInstaller.stripQuarantine(at: url)
            return try stageForNextLaunch(bundleAt: url, replacing: existing)
        }

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)
        let loadURL: URL
        if url.standardizedFileURL != destURL.standardizedFileURL {
            loadURL = try PluginInstaller.atomicReplace(stagedBundleURL: url, destURL: destURL)
        } else {
            loadURL = destURL
        }
        PluginInstaller.stripQuarantine(at: loadURL)
        removeRegistryMetadata(for: loadURL)
        return try await loadPluginAsync(at: loadURL, source: .userInstalled)
    }

    private func installLocalZip(from url: URL) async throws -> PluginEntry {
        let stagingRoot = PluginInstaller.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        try PluginInstaller.extractZip(at: url, into: workingDir)
        let bundleURL = try PluginInstaller.findBundle(in: workingDir)
        guard let bundle = Bundle(url: bundleURL) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(bundleURL.lastPathComponent)")
        }
        try PluginCodeSignatureVerifier.verify(bundle: bundle)
        try Self.validateBundleVersions(bundle)
        PluginInstaller.stripQuarantine(at: bundleURL)

        let bundleId = bundle.bundleIdentifier ?? bundleURL.lastPathComponent
        try reserveInstall(of: bundleId)
        defer { installsInFlight.remove(bundleId) }

        if let existing = plugins.first(where: { $0.id == bundleId }) {
            return try stageForNextLaunch(bundleAt: bundleURL, replacing: existing)
        }

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(bundleURL.lastPathComponent)
        let finalURL = try PluginInstaller.atomicReplace(stagedBundleURL: bundleURL, destURL: destURL)
        removeRegistryMetadata(for: finalURL)
        return try await loadPluginAsync(at: finalURL, source: .userInstalled)
    }

    func stageForNextLaunch(bundleAt bundleURL: URL, replacing existing: PluginEntry) throws -> PluginEntry {
        try PluginInstaller.stage(
            bundleAt: bundleURL,
            pluginId: existing.id,
            bundleName: existing.url.lastPathComponent,
            userPluginsDir: userPluginsDir
        )
        removeRegistryMetadata(for: existing.url)
        stagedPluginIds.insert(existing.id)
        return existing
    }
}

enum PluginUpdateOutcome: Sendable {
    case installed(PluginEntry)
    case staged(pluginId: String)
}
