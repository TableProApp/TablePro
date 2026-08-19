//
//  CloudSQLProxyBinaryManager.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

actor CloudSQLProxyBinaryManager {
    static let shared = CloudSQLProxyBinaryManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudSQLProxyBinary")

    static let pinnedVersion = "2.23.0"

    static let defaultExpectedSHA256: [String: String] = [
        "arm64": "d5233967a8b5141bd1e95edcad2fb9930357d3ffbd9f433b82fc4a538d3fd68b",
        "amd64": "8089f6bab724a68c5e47b74759671db091df44b36e84cd273c1b899068f7a173"
    ]

    private let baseDirectory: URL
    private let expectedSHA256: [String: String]
    private let fetch: @Sendable (URL) async throws -> Data
    private var downloadTask: Task<Void, Error>?

    init(
        baseDirectory: URL? = nil,
        expectedSHA256: [String: String] = CloudSQLProxyBinaryManager.defaultExpectedSHA256,
        fetch: @escaping @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    ) {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        self.baseDirectory = baseDirectory
            ?? appSupport.appendingPathComponent("TablePro/cloud-sql-proxy", isDirectory: true)
        self.expectedSHA256 = expectedSHA256
        self.fetch = fetch
    }

    var binaryExecutablePath: String {
        baseDirectory.appendingPathComponent("cloud-sql-proxy").path
    }

    /// Whether a managed binary is present at all, for the connection form's "Downloaded" state.
    ///
    /// This answers a question about the UI, not about trust, and it must never be the way the
    /// launch path obtains a path to execute. Use `ensureBinary()` for that, which verifies the
    /// pinned version and checksum first and reinstalls when either no longer matches.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryExecutablePath)
    }

    func installedVersion() -> String? {
        let versionFile = baseDirectory.appendingPathComponent("version.txt")
        return try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The binary is executed directly, so a stale version or an altered file must be
    /// refused rather than run. The checksum is re-read on every call because the file
    /// lives in a user-writable directory and is only ad-hoc signed, which leaves the
    /// pinned digest as the sole thing attesting to what is about to run.
    func installedBinaryIsCurrent() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryExecutablePath) else { return false }

        guard installedVersion() == Self.pinnedVersion else {
            Self.logger.info("cloud-sql-proxy on disk is not the pinned version, reinstalling")
            return false
        }

        guard let expected = expectedSHA256[Self.arch] else {
            Self.logger.error("No pinned cloud-sql-proxy checksum for \(Self.arch, privacy: .public)")
            return false
        }

        guard DownloadedBinary.sha256Hex(ofFileAt: binaryExecutablePath) == expected else {
            Self.logger.error("cloud-sql-proxy on disk does not match its pinned checksum, reinstalling")
            return false
        }
        return true
    }

    func ensureBinary() async throws -> String {
        if installedBinaryIsCurrent() {
            return binaryExecutablePath
        }

        if let existing = downloadTask {
            try await existing.value
            downloadTask = nil
        } else {
            let task = Task { try await downloadBinary() }
            downloadTask = task
            do {
                try await task.value
                downloadTask = nil
            } catch {
                downloadTask = nil
                throw error
            }
        }

        guard installedBinaryIsCurrent() else {
            throw CloudSQLProxyError.binaryNotFound
        }
        return binaryExecutablePath
    }

    private func downloadBinary() async throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let arch = Self.arch
        guard let expected = expectedSHA256[arch],
              let url = URL(
                  string: "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v\(Self.pinnedVersion)/cloud-sql-proxy.darwin.\(arch)"
              ) else {
            throw CloudSQLProxyError.binaryNotFound
        }

        let data = try await fetch(url)
        guard data.sha256HexString() == expected else {
            Self.logger.error("cloud-sql-proxy binary checksum mismatch, refusing to install")
            throw CloudSQLProxyError.binaryNotFound
        }

        let tempPath = baseDirectory.appendingPathComponent("cloud-sql-proxy.download")
        try data.write(to: tempPath, options: .atomic)
        if FileManager.default.fileExists(atPath: binaryExecutablePath) {
            try FileManager.default.removeItem(atPath: binaryExecutablePath)
        }
        try FileManager.default.moveItem(atPath: tempPath.path, toPath: binaryExecutablePath)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryExecutablePath)
        DownloadedBinary.stripQuarantine(at: URL(fileURLWithPath: binaryExecutablePath))

        let versionFile = baseDirectory.appendingPathComponent("version.txt")
        try Self.pinnedVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        Self.logger.info("Downloaded cloud-sql-proxy \(Self.pinnedVersion, privacy: .public)")
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
}

private extension Data {
    func sha256HexString() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
