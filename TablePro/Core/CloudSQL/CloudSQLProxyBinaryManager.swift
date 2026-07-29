//
//  CloudSQLProxyBinaryManager.swift
//  TablePro
//

import CryptoKit
import Darwin
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.baseDirectory = baseDirectory
            ?? appSupport.appendingPathComponent("TablePro/cloud-sql-proxy", isDirectory: true)
        self.expectedSHA256 = expectedSHA256
        self.fetch = fetch
    }

    var binaryExecutablePath: String {
        baseDirectory.appendingPathComponent("cloud-sql-proxy").path
    }

    var cachedBinaryPath: String? {
        FileManager.default.isExecutableFile(atPath: binaryExecutablePath) ? binaryExecutablePath : nil
    }

    func installedVersion() -> String? {
        let versionFile = baseDirectory.appendingPathComponent("version.txt")
        return try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ensureBinary() async throws -> String {
        if FileManager.default.isExecutableFile(atPath: binaryExecutablePath) {
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

        guard FileManager.default.isExecutableFile(atPath: binaryExecutablePath) else {
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
        stripQuarantineAttribute(at: binaryExecutablePath)

        let versionFile = baseDirectory.appendingPathComponent("version.txt")
        try? Self.pinnedVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        Self.logger.info("Downloaded cloud-sql-proxy \(Self.pinnedVersion, privacy: .public)")
    }

    private func stripQuarantineAttribute(at path: String) {
        let removed = path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        guard removed != 0 else { return }
        let err = errno
        if err != ENOATTR {
            Self.logger.warning("Failed to remove quarantine xattr: errno=\(err)")
        }
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
