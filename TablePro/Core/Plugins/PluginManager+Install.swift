//
//  PluginManager+Install.swift
//  TablePro
//

import Foundation
import os

extension PluginManager {
    func installFromRegistry(
        _ registryPlugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginEntry {
        let binary = try validateRegistryCompatibility(registryPlugin)
        if plugins.contains(where: { $0.id == registryPlugin.id }) {
            throw PluginError.pluginConflict(existingName: registryPlugin.name)
        }
        guard !installsInFlight.contains(registryPlugin.id) else {
            throw PluginError.installFailed(
                String(localized: "Another install is already in progress for this plugin")
            )
        }
        installsInFlight.insert(registryPlugin.id)
        defer { installsInFlight.remove(registryPlugin.id) }

        let userPluginsDir = self.userPluginsDir
        let stateHandler: @Sendable (StagedInstallState) async -> Void = { state in
            if case .downloading(let fraction) = state {
                await MainActor.run { progress(fraction) }
            }
        }

        let finalURL = try await PluginInstaller.shared.install(
            registryPlugin,
            binary: binary,
            into: userPluginsDir,
            progressHandler: stateHandler
        )

        saveRegistryMetadata(pluginId: registryPlugin.id, pluginURL: finalURL)
        let entry = try await loadPluginAsync(at: finalURL, source: .userInstalled)
        refreshRegistryUpdateSet()
        return entry
    }

    func updateFromRegistry(
        _ registryPlugin: RegistryPlugin,
        existingPluginLoaded: Bool = true,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginUpdateOutcome {
        let binary = try validateRegistryCompatibility(registryPlugin)

        if let existing = plugins.first(where: { $0.id == registryPlugin.id }),
           existing.source == .builtIn {
            throw PluginError.pluginConflict(existingName: existing.name)
        }

        guard !installsInFlight.contains(registryPlugin.id) else {
            throw PluginError.installFailed(
                String(localized: "Another install is already in progress for this plugin")
            )
        }
        installsInFlight.insert(registryPlugin.id)
        defer { installsInFlight.remove(registryPlugin.id) }

        let hasLive = pluginHasLiveConnections(registryPlugin)
        let userPluginsDir = self.userPluginsDir
        let stateHandler: @Sendable (StagedInstallState) async -> Void = { state in
            if case .downloading(let fraction) = state {
                await MainActor.run { progress(fraction) }
            }
        }

        let result = try await PluginInstaller.shared.update(
            registryPlugin,
            binary: binary,
            into: userPluginsDir,
            hasLiveConnections: hasLive,
            progressHandler: stateHandler
        )

        switch result {
        case .installed(let pluginURL):
            saveRegistryMetadata(pluginId: registryPlugin.id, pluginURL: pluginURL)
            let entry = try await loadPluginAsync(
                at: pluginURL,
                source: .userInstalled,
                replacingBundleId: registryPlugin.id
            )
            stagedUpdates.removeValue(forKey: registryPlugin.id)
            PluginInstallTracker.shared.completeInstall(pluginId: registryPlugin.id)
            refreshRegistryUpdateSet()
            return .installed(entry)
        case .staged(let stagedURL):
            stagedUpdates[registryPlugin.id] = StagedPluginUpdate(
                registryPlugin: registryPlugin,
                stagedURL: stagedURL
            )
            PluginInstallTracker.shared.markStaged(
                pluginId: registryPlugin.id,
                newVersion: registryPlugin.version
            )
            return .staged(pluginId: registryPlugin.id)
        }
    }

    func installPlugin(from url: URL) async throws -> PluginEntry {
        if url.pathExtension == "tableplugin" {
            return try await installLooseBundle(from: url)
        }
        return try await installLocalZip(from: url)
    }

    func commitStagedUpdate(pluginId: String) async throws -> PluginEntry {
        guard let pending = stagedUpdates[pluginId] else {
            throw PluginError.notFound
        }
        guard !pluginHasLiveConnections(pending.registryPlugin) else {
            throw PluginError.installFailed(
                String(localized: "Plugin has active connections")
            )
        }
        guard !installsInFlight.contains(pluginId) else {
            throw PluginError.installFailed(
                String(localized: "Another install is already in progress for this plugin")
            )
        }
        installsInFlight.insert(pluginId)
        defer {
            installsInFlight.remove(pluginId)
            stagedUpdates.removeValue(forKey: pluginId)
        }
        let finalURL = try await PluginInstaller.shared.commitStagedUpdate(
            pluginId: pluginId,
            into: userPluginsDir
        )
        saveRegistryMetadata(pluginId: pluginId, pluginURL: finalURL)
        let entry = try await loadPluginAsync(
            at: finalURL,
            source: .userInstalled,
            replacingBundleId: pluginId
        )
        PluginInstallTracker.shared.completeInstall(pluginId: pluginId)
        refreshRegistryUpdateSet()
        return entry
    }

    func discardStagedUpdate(pluginId: String) async {
        await PluginInstaller.shared.discardStagedUpdate(pluginId: pluginId)
        stagedUpdates.removeValue(forKey: pluginId)
        PluginInstallTracker.shared.clearInstall(pluginId: pluginId)
    }

    @discardableResult
    func validateRegistryCompatibility(_ registryPlugin: RegistryPlugin) throws -> RegistryBinary {
        if let minAppVersion = registryPlugin.minAppVersion {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.incompatibleWithCurrentApp(minimumRequired: minAppVersion)
            }
        }
        return try registryPlugin.resolvedBinary(
            for: .current,
            pluginKitVersion: Self.currentPluginKitVersion
        )
    }

    func pluginHasLiveConnections(_ registryPlugin: RegistryPlugin) -> Bool {
        let typeIds = Set(registryPlugin.databaseTypeIds ?? [registryPlugin.id])
        return DatabaseManager.shared.activeSessions.values.contains { session in
            typeIds.contains(session.connection.type.pluginTypeId)
        }
    }

    func reattemptStagedUpdates() {
        for (pluginId, pending) in stagedUpdates where !pluginHasLiveConnections(pending.registryPlugin) {
            guard !installsInFlight.contains(pluginId) else { continue }
            Task { [weak self] in
                _ = try? await self?.commitStagedUpdate(pluginId: pluginId)
            }
        }
    }

    // MARK: - Local bundle / zip install

    private func installLooseBundle(from url: URL) async throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }
        try PluginCodeSignatureVerifier.verify(bundle: sourceBundle)
        let bundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)
        let replaceId: String? = plugins.contains(where: { $0.id == bundleId }) ? bundleId : nil

        if url.standardizedFileURL != destURL.standardizedFileURL {
            let finalURL = try PluginInstaller.atomicReplace(stagedBundleURL: url, destURL: destURL)
            return try await loadPluginAsync(at: finalURL, source: .userInstalled, replacingBundleId: replaceId)
        }
        return try await loadPluginAsync(at: destURL, source: .userInstalled, replacingBundleId: replaceId)
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
        try PluginInstaller.validateStagedABI(
            bundleURL: bundleURL,
            currentKit: Self.currentPluginKitVersion,
            currentInspector: Self.currentInspectorKitVersion
        )
        PluginInstaller.stripQuarantine(at: bundleURL)

        let bundleId = bundle.bundleIdentifier ?? bundleURL.lastPathComponent
        let replaceId: String? = plugins.contains(where: { $0.id == bundleId }) ? bundleId : nil

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(bundleURL.lastPathComponent)
        let finalURL = try PluginInstaller.atomicReplace(stagedBundleURL: bundleURL, destURL: destURL)
        return try await loadPluginAsync(at: finalURL, source: .userInstalled, replacingBundleId: replaceId)
    }
}

enum PluginUpdateOutcome: Sendable {
    case installed(PluginEntry)
    case staged(pluginId: String)
}

struct StagedPluginUpdate: Sendable {
    let registryPlugin: RegistryPlugin
    let stagedURL: URL
}
