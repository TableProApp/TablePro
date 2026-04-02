//
//  ThemeRegistryInstaller.swift
//  TablePro
//
//  Handles install/uninstall/update of themes from the plugin registry.
//  Themes are pure JSON (no executable code, no .tableplugin bundles).
//

import CryptoKit
import Foundation
import os

@MainActor
@Observable
internal final class ThemeRegistryInstaller {
    static let shared = ThemeRegistryInstaller()

    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeRegistryInstaller")

    private init() {}

    // MARK: - Install

    func install(
        _ plugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard !isInstalled(plugin.id) else {
            throw PluginError.pluginConflict(existingName: plugin.name)
        }

        let decodedThemes = try await downloadAndDecode(plugin, progress: progress)

        var installedThemes: [InstalledRegistryTheme] = []

        for theme in decodedThemes {
            try ThemeStorage.saveRegistryTheme(theme)

            installedThemes.append(InstalledRegistryTheme(
                id: theme.id,
                registryPluginId: plugin.id,
                version: plugin.version,
                installedDate: Date()
            ))
        }

        var meta = ThemeStorage.loadRegistryMeta()
        meta.installed.append(contentsOf: installedThemes)
        try ThemeStorage.saveRegistryMeta(meta)

        ThemeEngine.shared.reloadAvailableThemes()
        progress(1.0)

        Self.logger.info("Installed \(installedThemes.count) theme(s) from registry plugin: \(plugin.id)")
    }

    // MARK: - Uninstall

    func uninstall(registryPluginId: String) throws {
        let removedThemeIds = try removeRegistryFiles(for: registryPluginId)

        ThemeEngine.shared.reloadAvailableThemes()

        // Reset preferred theme slots if the uninstalled theme was preferred
        var appearance = AppSettingsManager.shared.appearance
        var changed = false
        for id in removedThemeIds {
            if id == appearance.preferredLightThemeId {
                appearance.preferredLightThemeId = "tablepro.default-light"
                changed = true
            }
            if id == appearance.preferredDarkThemeId {
                appearance.preferredDarkThemeId = "tablepro.default-dark"
                changed = true
            }
        }
        if changed {
            AppSettingsManager.shared.appearance = appearance
        }

        Self.logger.info("Uninstalled registry themes for plugin: \(registryPluginId)")
    }

    // MARK: - Update

    func update(
        _ plugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let activeId = ThemeEngine.shared.activeTheme.id

        // Download, verify, and decode new themes first (no side effects yet)
        let stagedThemes = try await downloadAndDecode(plugin, progress: progress)

        // Remove old files without triggering theme reload or fallback
        _ = try removeRegistryFiles(for: plugin.id)

        // Write new themes
        var installedThemes: [InstalledRegistryTheme] = []
        for theme in stagedThemes {
            try ThemeStorage.saveRegistryTheme(theme)
            installedThemes.append(InstalledRegistryTheme(
                id: theme.id,
                registryPluginId: plugin.id,
                version: plugin.version,
                installedDate: Date()
            ))
        }

        var meta = ThemeStorage.loadRegistryMeta()
        meta.installed.append(contentsOf: installedThemes)
        try ThemeStorage.saveRegistryMeta(meta)

        // Single reload after swap is complete — no intermediate flicker
        ThemeEngine.shared.reloadAvailableThemes()

        // Re-activate the correct theme for the current appearance
        let appearance = AppSettingsManager.shared.appearance
        ThemeEngine.shared.updateAppearanceAndTheme(
            mode: appearance.appearanceMode,
            lightThemeId: appearance.preferredLightThemeId,
            darkThemeId: appearance.preferredDarkThemeId
        )

        Self.logger.info("Updated \(installedThemes.count) theme(s) for registry plugin: \(plugin.id)")
    }

    /// Removes meta entries and files for a registry plugin. Returns removed theme IDs.
    /// Does NOT reload ThemeEngine or trigger fallback — callers manage that.
    @discardableResult
    private func removeRegistryFiles(for registryPluginId: String) throws -> Set<String> {
        var meta = ThemeStorage.loadRegistryMeta()
        let themesToRemove = meta.installed.filter { $0.registryPluginId == registryPluginId }
        let removedIds = Set(themesToRemove.map(\.id))

        meta.installed.removeAll { $0.registryPluginId == registryPluginId }
        try ThemeStorage.saveRegistryMeta(meta)

        for entry in themesToRemove {
            do {
                try ThemeStorage.deleteRegistryTheme(id: entry.id)
            } catch {
                Self.logger.warning("Failed to delete registry theme file \(entry.id): \(error)")
            }
        }

        return removedIds
    }

    // MARK: - Query

    func isInstalled(_ registryPluginId: String) -> Bool {
        let meta = ThemeStorage.loadRegistryMeta()
        return meta.installed.contains { $0.registryPluginId == registryPluginId }
    }

    func installedVersion(for registryPluginId: String) -> String? {
        let meta = ThemeStorage.loadRegistryMeta()
        return meta.installed.first { $0.registryPluginId == registryPluginId }?.version
    }

    func availableUpdates(manifest: RegistryManifest) -> [RegistryPlugin] {
        let meta = ThemeStorage.loadRegistryMeta()
        let installedVersions = Dictionary(
            meta.installed.map { ($0.registryPluginId, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )

        return manifest.plugins.filter { plugin in
            guard plugin.category == .theme,
                  let installed = installedVersions[plugin.id] else { return false }
            return plugin.version.compare(installed, options: .numeric) == .orderedDescending
        }
    }

    // MARK: - Download & Decode

    private func downloadAndDecode(
        _ plugin: RegistryPlugin,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> [ThemeDefinition] {
        if let minAppVersion = plugin.minAppVersion {
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            if appVersion.compare(minAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.incompatibleWithCurrentApp(minimumRequired: minAppVersion)
            }
        }

        let resolved = try plugin.resolvedBinary()

        guard let downloadURL = URL(string: resolved.url) else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = RegistryClient.shared.session
        let (tempDownloadURL, response) = try await session.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
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

        progress(0.7)

        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let zipPath = tempDir.appendingPathComponent("theme.zip")
        try FileManager.default.moveItem(at: tempDownloadURL, to: zipPath)

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", zipPath.path, extractDir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PluginError.installFailed("Failed to extract theme archive")
            }
        }.value

        let jsonFiles = try findJsonFiles(in: extractDir)
        guard !jsonFiles.isEmpty else {
            throw PluginError.installFailed("No theme files found in archive")
        }

        progress(0.9)

        let decoder = JSONDecoder()
        var decodedThemes: [ThemeDefinition] = []

        for jsonURL in jsonFiles {
            let data = try Data(contentsOf: jsonURL)
            var theme = try decoder.decode(ThemeDefinition.self, from: data)
            let originalId = theme.id
            theme.id = "registry.\(plugin.id).\(originalId)"
            decodedThemes.append(theme)
        }

        let ids = decodedThemes.map(\.id)
        guard ids.count == Set(ids).count else {
            throw PluginError.installFailed("Theme pack contains duplicate IDs after namespace rewrite")
        }

        return decodedThemes
    }

    // MARK: - Helpers

    private func findJsonFiles(in directory: URL) throws -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "json" &&
                fileURL.lastPathComponent != "registry-meta.json" {
                results.append(fileURL)
            }
        }

        return results
    }
}
