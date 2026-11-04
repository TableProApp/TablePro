import Foundation
import os
import TableProProcess
import TableProUtilities

protocol RegistryPluginInstalling: Sendable {
    func install(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL

    func stage(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        pluginId: String,
        bundleName: String,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL
}

actor PluginInstaller: RegistryPluginInstalling {
    static let shared = PluginInstaller()

    static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstaller")

    private let session: @Sendable () async -> URLSession

    init(session: @escaping @Sendable () async -> URLSession = { await MainActor.run { RegistryClient.shared.session } }) {
        self.session = session
    }

    func install(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let extracted = try await downloadExtractVerify(
            registryPlugin,
            release: release,
            into: userPluginsDir,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: extracted.workingDir) }

        let destURL = userPluginsDir.appendingPathComponent(extracted.bundleURL.lastPathComponent, isDirectory: true)
        return try Self.atomicReplace(stagedBundleURL: extracted.bundleURL, destURL: destURL)
    }

    func stage(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        pluginId: String,
        bundleName: String,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        let extracted = try await downloadExtractVerify(
            registryPlugin,
            release: release,
            into: userPluginsDir,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: extracted.workingDir) }

        return try Self.stage(
            bundleAt: extracted.bundleURL,
            pluginId: pluginId,
            bundleName: bundleName,
            userPluginsDir: userPluginsDir
        )
    }

    // MARK: - Download / extract / verify / quarantine-strip

    private struct ExtractedBundle {
        let workingDir: URL
        let bundleURL: URL
    }

    private func downloadExtractVerify(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ExtractedBundle {
        // The manifest is network input: the signature check is the real gate, but nothing travels over cleartext.
        guard let downloadURL = URL(string: release.url),
              downloadURL.scheme?.lowercased() == "https" else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        let stagingRoot = Self.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        do {
            let urlSession = await self.session()
            let (tempDownloadURL, response) = try await Self.download(downloadURL, with: urlSession, progress: progress)
            let zipURL = workingDir.appendingPathComponent("\(registryPlugin.id).zip")
            try FileManager.default.moveItem(at: tempDownloadURL, to: zipURL)
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw PluginError.downloadFailed("HTTP \(code)")
            }
            guard DownloadedBinary.sha256Hex(ofFileAt: zipURL.path) == release.sha256.lowercased() else {
                throw PluginError.checksumMismatch
            }

            try Self.extractZip(at: zipURL, into: workingDir)

            let bundleURL = try Self.findBundle(in: workingDir)
            guard let stagedBundle = Bundle(url: bundleURL) else {
                throw PluginError.invalidBundle("Cannot create bundle from \(bundleURL.lastPathComponent)")
            }

            try PluginCodeSignatureVerifier.verify(bundle: stagedBundle)
            try Self.validateBundle(stagedBundle, against: release, pluginId: registryPlugin.id)
            Self.stripQuarantine(at: bundleURL)
            try Task.checkCancellation()

            return ExtractedBundle(workingDir: workingDir, bundleURL: bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: workingDir)
            throw error
        }
    }

    // MARK: - Helpers (nonisolated)

    nonisolated static func download(
        _ url: URL,
        with session: URLSession,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> (URL, URLResponse) {
        try await ProgressReportingDownload.download(url, with: session, progress: progress)
    }

    nonisolated static func stagingRoot(for userPluginsDir: URL) -> URL {
        userPluginsDir.deletingLastPathComponent()
            .appendingPathComponent("PluginStaging", isDirectory: true)
    }

    nonisolated static func stagedUpdatesRoot(for userPluginsDir: URL) -> URL {
        stagingRoot(for: userPluginsDir).appendingPathComponent("Updates", isDirectory: true)
    }

    nonisolated static func stagedUpdateDirectory(for pluginId: String, in userPluginsDir: URL) -> URL {
        stagedUpdatesRoot(for: userPluginsDir).appendingPathComponent(pluginId, isDirectory: true)
    }

    @discardableResult
    nonisolated static func stage(
        bundleAt bundleURL: URL,
        pluginId: String,
        bundleName: String,
        userPluginsDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        let stagedDir = stagedUpdateDirectory(for: pluginId, in: userPluginsDir)
        if fm.fileExists(atPath: stagedDir.path) {
            try fm.removeItem(at: stagedDir)
        }
        try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedURL = stagedDir.appendingPathComponent(bundleName, isDirectory: true)
        try fm.moveItem(at: bundleURL, to: stagedURL)
        return stagedURL
    }

    // --noqtn: the signature check is the gate, and the bundle drops quarantine after it either way.
    nonisolated static func extractZipCommand(at zipURL: URL, into destDir: URL) -> ProcessCommand {
        ProcessCommand(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", "--noqtn", "--", zipURL.path, destDir.path],
            environment: ProcessEnvironment.minimal()
        )
    }

    nonisolated static func extractZip(at zipURL: URL, into destDir: URL) throws {
        let process = try ProcessLauncher.process(for: extractZipCommand(at: zipURL, into: destDir))
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
        DownloadedBinary.stripQuarantine(at: url)
    }

    // The archive must be the build and the plugin its manifest entry names, as registry.py checks when it publishes.
    nonisolated static func validateBundle(_ bundle: Bundle, against release: RegistryRelease, pluginId: String) throws {
        try PluginManager.validateBundleVersions(bundle)
        let info = PluginManager.infoPlist(at: bundle.bundleURL)
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == pluginId else {
            throw PluginError.installFailed(String(
                format: String(localized: "The archive holds the plugin %1$@, not %2$@."),
                identifier,
                pluginId
            ))
        }
        let build = PluginManager.bundleBuild(at: bundle.bundleURL)
        guard build == release.build else {
            throw PluginError.installFailed(String(
                format: String(localized: "The archive holds build %1$ld, not build %2$ld."),
                build,
                release.build
            ))
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
        } else {
            try FileManager.default.moveItem(at: stagedBundleURL, to: destURL)
        }

        return (resultURL as URL?) ?? destURL
    }
}
