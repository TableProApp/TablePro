//
//  PluginManager+Registry.swift
//  TablePro
//

import CryptoKit
import Foundation

extension PluginManager {
    func installFromRegistry(
        _ registryPlugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginEntry {
        guard !isInstalling else {
            throw PluginError.installFailed("Another plugin installation is already in progress")
        }
        isInstalling = true
        defer { isInstalling = false }

        try validateRegistryCompatibility(registryPlugin)

        if plugins.contains(where: { $0.id == registryPlugin.id }) {
            throw PluginError.pluginConflict(existingName: registryPlugin.name)
        }

        return try await downloadAndInstall(registryPlugin, progress: progress)
    }

    func updateFromRegistry(
        _ registryPlugin: RegistryPlugin,
        existingPluginLoaded: Bool = true,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginEntry {
        guard !isInstalling else {
            throw PluginError.installFailed("Another plugin installation is already in progress")
        }
        isInstalling = true
        defer { isInstalling = false }

        try validateRegistryCompatibility(registryPlugin)

        replaceExistingPlugin(bundleId: registryPlugin.id)

        let entry = try await downloadAndInstall(registryPlugin, progress: progress)

        if existingPluginLoaded {
            needsRestart = true
        }

        return entry
    }

    private func validateRegistryCompatibility(_ registryPlugin: RegistryPlugin) throws {
        if let minAppVersion = registryPlugin.minAppVersion {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.incompatibleWithCurrentApp(minimumRequired: minAppVersion)
            }
        }

        if let minKit = registryPlugin.minPluginKitVersion, minKit > Self.currentPluginKitVersion {
            throw PluginError.incompatibleVersion(required: minKit, current: Self.currentPluginKitVersion)
        }
    }

    private func downloadAndInstall(
        _ registryPlugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> PluginEntry {
        let resolved = try registryPlugin.resolvedBinary()

        guard let downloadURL = URL(string: resolved.url) else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempZipURL = tempDir.appendingPathComponent("\(registryPlugin.id).zip")

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = RegistryClient.shared.session
        let (tempDownloadURL, response) = try await session.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PluginError.downloadFailed("HTTP \(statusCode)")
        }

        progress(0.5)

        let downloadedData = try Data(contentsOf: tempDownloadURL)
        let digest = SHA256.hash(data: downloadedData)
        let hexChecksum = digest.map { String(format: "%02x", $0) }.joined()

        if hexChecksum != resolved.sha256.lowercased() {
            throw PluginError.checksumMismatch
        }

        progress(1.0)

        try FileManager.default.moveItem(at: tempDownloadURL, to: tempZipURL)

        let entry = try await performInstallAssumingLock(from: tempZipURL)

        saveRegistryMetadata(
            pluginId: registryPlugin.id,
            pluginURL: entry.url
        )

        return entry
    }
}
