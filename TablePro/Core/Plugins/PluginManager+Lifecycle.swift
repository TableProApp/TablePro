//
//  PluginManager+Lifecycle.swift
//  TablePro
//

import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

// MARK: - Enable / Disable

extension PluginManager {
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
        return try await performInstallAssumingLock(from: url)
    }

    func performInstallAssumingLock(from url: URL) async throws -> PluginEntry {
        if url.pathExtension == "tableplugin" {
            return try await installBundle(from: url)
        } else {
            return try await installFromZip(from: url)
        }
    }

    private func installBundle(from url: URL) async throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }

        try verifyCodeSignature(bundle: sourceBundle)

        let newBundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent
        replaceExistingPlugin(bundleId: newBundleId)

        let fm = FileManager.default
        try fm.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)

        if url.standardizedFileURL != destURL.standardizedFileURL {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
        }

        let entry = try await loadPluginAsync(at: destURL, source: .userInstalled)

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

        guard extractedBundles.count == 1 else {
            throw PluginError.installFailed(
                "Archive contains \(extractedBundles.count) plugins; only single-plugin archives are supported"
            )
        }

        let extracted = extractedBundles[0]
        guard let extractedBundle = Bundle(url: extracted) else {
            throw PluginError.invalidBundle("Cannot create bundle from extracted plugin '\(extracted.lastPathComponent)'")
        }

        try verifyCodeSignature(bundle: extractedBundle)

        let newBundleId = extractedBundle.bundleIdentifier ?? extracted.lastPathComponent
        replaceExistingPlugin(bundleId: newBundleId)

        try fm.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(extracted.lastPathComponent)

        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: extracted, to: destURL)

        let entry = try await loadPluginAsync(at: destURL, source: .userInstalled)
        Self.logger.info("Installed plugin '\(entry.name)' v\(entry.version)")
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
        needsRestart = true
    }
}
