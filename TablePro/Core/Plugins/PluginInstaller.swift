//
//  PluginInstaller.swift
//  TablePro
//

import CryptoKit
import Darwin
import Foundation
import os

actor PluginInstaller {
    static let shared = PluginInstaller()

    static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstaller")

    private var activeTasks: [String: Task<URL, Error>] = [:]
    private var stagedUpdates: [String: URL] = [:]

    private init() {}

    func install(
        _ registryPlugin: RegistryPlugin,
        binary: RegistryBinary,
        into userPluginsDir: URL,
        progressHandler: @escaping @Sendable (StagedInstallState) async -> Void
    ) async throws -> URL {
        try await runCoalesced(pluginId: registryPlugin.id) {
            try await self.performDownloadAndCommit(
                registryPlugin,
                binary: binary,
                into: userPluginsDir,
                progressHandler: progressHandler
            )
        }
    }

    func update(
        _ registryPlugin: RegistryPlugin,
        binary: RegistryBinary,
        into userPluginsDir: URL,
        hasLiveConnections: Bool,
        progressHandler: @escaping @Sendable (StagedInstallState) async -> Void
    ) async throws -> PluginUpdateResult {
        if hasLiveConnections {
            let stagedURL = try await runCoalesced(pluginId: registryPlugin.id) {
                try await self.performDownloadAndStage(
                    registryPlugin,
                    binary: binary,
                    into: userPluginsDir,
                    progressHandler: progressHandler
                )
            }
            stagedUpdates[registryPlugin.id] = stagedURL
            await progressHandler(.staged(at: stagedURL))
            return .staged(at: stagedURL)
        }

        let finalURL = try await runCoalesced(pluginId: registryPlugin.id) {
            try await self.performDownloadAndCommit(
                registryPlugin,
                binary: binary,
                into: userPluginsDir,
                progressHandler: progressHandler
            )
        }
        return .installed(pluginURL: finalURL)
    }

    func commitStagedUpdate(pluginId: String, into userPluginsDir: URL) async throws -> URL {
        guard let stagedURL = stagedUpdates[pluginId] else {
            throw PluginError.notFound
        }
        let bundleName = stagedURL.deletingPathExtension().lastPathComponent
        let destURL = userPluginsDir.appendingPathComponent("\(bundleName).tableplugin", isDirectory: true)
        let finalURL = try Self.atomicReplace(stagedBundleURL: stagedURL, destURL: destURL)
        stagedUpdates.removeValue(forKey: pluginId)
        try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
        return finalURL
    }

    func discardStagedUpdate(pluginId: String) {
        guard let stagedURL = stagedUpdates.removeValue(forKey: pluginId) else { return }
        try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
    }

    func hasStagedUpdate(pluginId: String) -> Bool {
        stagedUpdates[pluginId] != nil
    }

    func stagedURL(for pluginId: String) -> URL? {
        stagedUpdates[pluginId]
    }

    func cancelInstall(pluginId: String) {
        activeTasks[pluginId]?.cancel()
    }

    // MARK: - Coalescing

    private func runCoalesced(
        pluginId: String,
        body: @Sendable @escaping () async throws -> URL
    ) async throws -> URL {
        if let existing = activeTasks[pluginId] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try await body()
        }
        activeTasks[pluginId] = task
        defer { activeTasks.removeValue(forKey: pluginId) }
        return try await task.value
    }

    // MARK: - Download + commit (no live connections)

    private func performDownloadAndCommit(
        _ registryPlugin: RegistryPlugin,
        binary: RegistryBinary,
        into userPluginsDir: URL,
        progressHandler: @escaping @Sendable (StagedInstallState) async -> Void
    ) async throws -> URL {
        let extracted = try await downloadExtractVerify(
            registryPlugin,
            binary: binary,
            into: userPluginsDir,
            progressHandler: progressHandler
        )

        defer {
            try? FileManager.default.removeItem(at: extracted.workingDir)
        }

        let destURL = userPluginsDir.appendingPathComponent(extracted.bundleURL.lastPathComponent, isDirectory: true)
        let finalURL = try Self.atomicReplace(stagedBundleURL: extracted.bundleURL, destURL: destURL)
        await progressHandler(.installed(pluginURL: finalURL))
        return finalURL
    }

    // MARK: - Download + stage (live connections)

    private func performDownloadAndStage(
        _ registryPlugin: RegistryPlugin,
        binary: RegistryBinary,
        into userPluginsDir: URL,
        progressHandler: @escaping @Sendable (StagedInstallState) async -> Void
    ) async throws -> URL {
        let extracted = try await downloadExtractVerify(
            registryPlugin,
            binary: binary,
            into: userPluginsDir,
            progressHandler: progressHandler
        )
        return extracted.bundleURL
    }

    // MARK: - Download / extract / verify / quarantine-strip

    private struct ExtractedBundle {
        let workingDir: URL
        let bundleURL: URL
    }

    private func downloadExtractVerify(
        _ registryPlugin: RegistryPlugin,
        binary: RegistryBinary,
        into userPluginsDir: URL,
        progressHandler: @escaping @Sendable (StagedInstallState) async -> Void
    ) async throws -> ExtractedBundle {
        let stagingRoot = Self.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let context = await MainActor.run {
            (
                kit: PluginManager.currentPluginKitVersion,
                inspector: PluginManager.currentInspectorKitVersion,
                session: RegistryClient.shared.session
            )
        }

        guard let downloadURL = URL(string: binary.downloadURL) else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        await progressHandler(.downloading(fraction: 0))

        let (tempDownloadURL, response) = try await context.session.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PluginError.downloadFailed("HTTP \(code)")
        }

        await progressHandler(.downloading(fraction: 0.5))

        let payload = try Data(contentsOf: tempDownloadURL)
        let digest = SHA256.hash(data: payload)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == binary.sha256.lowercased() else {
            throw PluginError.checksumMismatch
        }

        await progressHandler(.downloading(fraction: 1.0))

        let zipURL = workingDir.appendingPathComponent("\(registryPlugin.id).zip")
        try FileManager.default.moveItem(at: tempDownloadURL, to: zipURL)

        try Self.extractZip(at: zipURL, into: workingDir)

        let bundleURL = try Self.findBundle(in: workingDir)
        guard let stagedBundle = Bundle(url: bundleURL) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(bundleURL.lastPathComponent)")
        }

        try PluginCodeSignatureVerifier.verify(bundle: stagedBundle)

        try Self.validateStagedABI(
            bundleURL: bundleURL,
            currentKit: context.kit,
            currentInspector: context.inspector
        )
        Self.stripQuarantine(at: bundleURL)

        return ExtractedBundle(workingDir: workingDir, bundleURL: bundleURL)
    }

    // MARK: - Helpers (nonisolated)

    nonisolated static func stagingRoot(for userPluginsDir: URL) -> URL {
        userPluginsDir.deletingLastPathComponent()
            .appendingPathComponent("PluginStaging", isDirectory: true)
    }

    nonisolated static func extractZip(at zipURL: URL, into destDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, destDir.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw PluginError.installFailed("ditto exit code \(process.terminationStatus)")
        }
    }

    nonisolated static func findBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "tableplugin" }

        guard !contents.isEmpty else {
            throw PluginError.installFailed("No .tableplugin bundle found in archive")
        }
        guard contents.count == 1 else {
            throw PluginError.installFailed("Archive contains \(contents.count) plugins; only single-plugin archives are supported")
        }
        return contents[0]
    }

    nonisolated static func stripQuarantine(at url: URL) {
        let path = url.path
        let result = path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        guard result != 0 else { return }
        let code = errno
        if code != ENOATTR {
            logger.warning("Failed to remove quarantine xattr at \(url.lastPathComponent): errno=\(code)")
        }
    }

    nonisolated static func validateStagedABI(
        bundleURL: URL,
        currentKit: Int,
        currentInspector: Int
    ) throws {
        guard let bundle = Bundle(url: bundleURL),
              let info = bundle.infoDictionary
        else {
            throw PluginError.invalidBundle("Cannot read Info.plist")
        }
        let declaredKit = info["TableProPluginKitVersion"] as? Int
        let declaredInspector = info["TableProInspectorKitVersion"] as? Int
        if declaredKit == nil && declaredInspector == nil {
            throw PluginError.pluginOutdated(pluginVersion: 0, requiredVersion: currentKit)
        }
        if let version = declaredKit {
            if version > currentKit {
                throw PluginError.incompatibleVersion(required: version, current: currentKit)
            }
            if version < currentKit {
                throw PluginError.pluginOutdated(pluginVersion: version, requiredVersion: currentKit)
            }
        }
        if let version = declaredInspector {
            if version > currentInspector {
                throw PluginError.incompatibleVersion(required: version, current: currentInspector)
            }
            if version < currentInspector {
                throw PluginError.pluginOutdated(pluginVersion: version, requiredVersion: currentInspector)
            }
        }
    }

    nonisolated static func atomicReplace(stagedBundleURL: URL, destURL: URL) throws -> URL {
        var resultURL: NSURL?
        let backupName = "\(destURL.lastPathComponent).bak"
        let destDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.replaceItem(
                at: destURL,
                withItemAt: stagedBundleURL,
                backupItemName: backupName,
                options: [],
                resultingItemURL: &resultURL
            )
            let backupURL = destDir.appendingPathComponent(backupName)
            try? FileManager.default.removeItem(at: backupURL)
        } else {
            try FileManager.default.moveItem(at: stagedBundleURL, to: destURL)
        }

        return (resultURL as URL?) ?? destURL
    }
}

enum StagedInstallState: Sendable {
    case downloading(fraction: Double)
    case staged(at: URL)
    case installed(pluginURL: URL)
    case failed(any Error)
}

enum PluginUpdateResult: Sendable {
    case installed(pluginURL: URL)
    case staged(at: URL)
}
