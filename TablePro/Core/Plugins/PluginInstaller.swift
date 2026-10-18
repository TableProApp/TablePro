import Foundation
import os
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

    private init() {}

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
        let stagingRoot = Self.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let session = await MainActor.run { RegistryClient.shared.session }

        // The manifest is network input: the signature check is the real gate, but nothing travels over cleartext.
        guard let downloadURL = URL(string: release.url),
              downloadURL.scheme?.lowercased() == "https" else {
            throw PluginError.downloadFailed("Invalid download URL")
        }

        let (tempDownloadURL, response) = try await Self.download(downloadURL, with: session, progress: progress)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PluginError.downloadFailed("HTTP \(code)")
        }

        guard DownloadedBinary.sha256Hex(ofFileAt: tempDownloadURL.path) == release.sha256.lowercased() else {
            throw PluginError.checksumMismatch
        }

        let zipURL = workingDir.appendingPathComponent("\(registryPlugin.id).zip")
        try FileManager.default.moveItem(at: tempDownloadURL, to: zipURL)

        try Self.extractZip(at: zipURL, into: workingDir)

        let bundleURL = try Self.findBundle(in: workingDir)
        guard let stagedBundle = Bundle(url: bundleURL) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(bundleURL.lastPathComponent)")
        }

        try PluginCodeSignatureVerifier.verify(bundle: stagedBundle)
        try PluginManager.validateBundleVersions(stagedBundle)
        Self.stripQuarantine(at: bundleURL)

        return ExtractedBundle(workingDir: workingDir, bundleURL: bundleURL)
    }

    // MARK: - Helpers (nonisolated)

    nonisolated static func download(
        _ url: URL,
        with session: URLSession,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> (URL, URLResponse) {
        let observer = DownloadProgressObserver()
        let forwarding = Task {
            for await fraction in observer.fractions {
                await progress(fraction)
            }
        }
        do {
            let result = try await session.download(from: url, delegate: observer)
            observer.finish(isComplete: true)
            await forwarding.value
            return result
        } catch {
            observer.finish(isComplete: false)
            forwarding.cancel()
            throw error
        }
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
        DownloadedBinary.stripQuarantine(at: url)
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

// The async download sends a task delegate no byte callbacks, but the task's own progress moves.
private final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, Sendable {
    let fractions: AsyncStream<Double>
    private let continuation: AsyncStream<Double>.Continuation
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(uncheckedState: nil)

    override init() {
        (fractions, continuation) = AsyncStream.makeStream(of: Double.self)
        super.init()
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let continuation = continuation
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            // Without a Content-Length the fraction creeps on a guess; the UI stays indeterminate.
            guard task.countOfBytesExpectedToReceive > 0 else { return }
            continuation.yield(progress.fractionCompleted)
        }
        self.observation.withLockUnchecked { $0 = observation }
    }

    func finish(isComplete: Bool) {
        observation.withLockUnchecked { observation in
            observation?.invalidate()
            observation = nil
        }
        if isComplete {
            continuation.yield(1)
        }
        continuation.finish()
    }
}
