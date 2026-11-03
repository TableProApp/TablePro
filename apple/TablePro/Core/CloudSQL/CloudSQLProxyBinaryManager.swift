//
//  CloudSQLProxyBinaryManager.swift
//  TablePro
//

import Foundation
import os
import TableProUtilities

actor CloudSQLProxyBinaryManager {
    typealias Download = @Sendable (
        _ url: URL,
        _ progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> (URL, URLResponse)

    static let shared = CloudSQLProxyBinaryManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudSQLProxyBinary")

    static let pinnedVersion = "2.23.0"

    static let defaultExpectedSHA256: [String: String] = [
        "arm64": "d5233967a8b5141bd1e95edcad2fb9930357d3ffbd9f433b82fc4a538d3fd68b",
        "amd64": "8089f6bab724a68c5e47b74759671db091df44b36e84cd273c1b899068f7a173"
    ]

    nonisolated let binaryExecutablePath: String
    private let baseDirectory: URL
    private let expectedSHA256: [String: String]
    private let download: Download

    init(
        baseDirectory: URL? = nil,
        expectedSHA256: [String: String] = CloudSQLProxyBinaryManager.defaultExpectedSHA256,
        download: @escaping Download = { url, progress in
            try await ProgressReportingDownload.download(url, with: .shared, progress: progress)
        }
    ) {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        let directory = baseDirectory
            ?? appSupport.appendingPathComponent("TablePro/cloud-sql-proxy", isDirectory: true)
        self.baseDirectory = directory
        self.binaryExecutablePath = directory.appendingPathComponent("cloud-sql-proxy").path
        self.expectedSHA256 = expectedSHA256
        self.download = download
    }

    func installedVersion() -> String? {
        try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The file is ad-hoc signed in a user-writable folder, so the pinned digest, re-read on every call, is all that vouches for it.
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

    // Runs in the caller's task, so cancelling the caller cancels the download.
    func ensureBinary(progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> String {
        if installedBinaryIsCurrent() {
            return binaryExecutablePath
        }
        try await install(progress: progress)
        guard installedBinaryIsCurrent() else {
            throw CloudSQLProxyError.binaryNotFound
        }
        return binaryExecutablePath
    }

    private var versionFile: URL {
        baseDirectory.appendingPathComponent("version.txt")
    }

    private func install(progress: @escaping @Sendable (Double) async -> Void) async throws {
        let arch = Self.arch
        guard let expected = expectedSHA256[arch],
              let url = URL(
                  string: "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v\(Self.pinnedVersion)/cloud-sql-proxy.darwin.\(arch)"
              ) else {
            throw CloudSQLProxyError.binaryNotFound
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await download(url, progress)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        defer { try? fileManager.removeItem(at: downloaded) }
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Self.logger.error("cloud-sql-proxy download answered HTTP \(http.statusCode, privacy: .public)")
            throw CloudSQLProxyError.downloadFailed(statusCode: http.statusCode)
        }

        guard DownloadedBinary.sha256Hex(ofFileAt: downloaded.path) == expected else {
            Self.logger.error("cloud-sql-proxy binary checksum mismatch, refusing to install")
            throw CloudSQLProxyError.checksumMismatch
        }

        let staged = baseDirectory.appendingPathComponent("cloud-sql-proxy.\(UUID().uuidString).download")
        try fileManager.moveItem(at: downloaded, to: staged)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        DownloadedBinary.stripQuarantine(at: staged)
        try Task.checkCancellation()

        // A swap rather than remove-then-move, so a failure here leaves the previous binary in place.
        let destination = URL(fileURLWithPath: binaryExecutablePath)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }

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
