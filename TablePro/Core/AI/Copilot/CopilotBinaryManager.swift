//
//  CopilotBinaryManager.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

struct CopilotBinaryDigests: Sendable, Equatable {
    let tarballSHA256: String
    let binarySHA256: String
}

actor CopilotBinaryManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotBinary")
    static let shared = CopilotBinaryManager()

    /// Bumped by an app release, never resolved at runtime, so what runs is what was reviewed.
    static let pinnedVersion = "1.551.2"

    static let defaultPinnedDigests: [String: CopilotBinaryDigests] = [
        "darwin-arm64": CopilotBinaryDigests(
            tarballSHA256: "3dd2f395464629759bdb149af4c1551c0b1282d1183956d5cac56e1238863e02",
            binarySHA256: "8e13bc14e015eb77a85bff574ee3c1b29a6d87577d9ab09c95f44ed200d166f2"
        ),
        "darwin-x64": CopilotBinaryDigests(
            tarballSHA256: "8b47ac2d86b36a4298b65dfa6661cb118c9bf64b114d8a0f7e502633c6a6ea0d",
            binarySHA256: "864336325b534b22c4851d7b056ddf4daaf057ee70ac504d33f6db168ca7f4dc"
        )
    ]

    private let baseDirectory: URL
    private let pinnedDigests: [String: CopilotBinaryDigests]
    private let fetch: @Sendable (URL) async throws -> Data
    private var downloadTask: Task<Void, Error>?

    init(
        baseDirectory: URL? = nil,
        pinnedDigests: [String: CopilotBinaryDigests] = CopilotBinaryManager.defaultPinnedDigests,
        fetch: @escaping @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    ) {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        self.baseDirectory = baseDirectory
            ?? appSupport.appendingPathComponent("TablePro/copilot-language-server", isDirectory: true)
        self.pinnedDigests = pinnedDigests
        self.fetch = fetch
    }

    static var tarballURL: URL? {
        URL(string: "https://registry.npmjs.org/@github/copilot-language-server-\(platform)/-/copilot-language-server-\(platform)-\(pinnedVersion).tgz")
    }

    /// Re-read on every launch: the binary lives in a user-writable directory, so the pinned
    /// digest is the only thing attesting to what is about to run.
    func installedBinaryIsCurrent() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryExecutablePath) else { return false }

        guard installedVersion() == Self.pinnedVersion else {
            Self.logger.info("Copilot language server on disk is not the pinned version, reinstalling")
            return false
        }

        guard let expected = pinnedDigests[Self.platform]?.binarySHA256 else {
            Self.logger.error("No pinned Copilot language server digest for \(Self.platform, privacy: .public)")
            return false
        }

        guard DownloadedBinary.sha256Hex(ofFileAt: binaryExecutablePath) == expected else {
            Self.logger.error("Copilot language server on disk does not match its pinned digest, reinstalling")
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
            throw CopilotError.binaryNotFound
        }
        return binaryExecutablePath
    }

    func installedVersion() -> String? {
        try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadBinary() async throws {
        guard let digests = pinnedDigests[Self.platform], let url = Self.tarballURL else {
            throw CopilotError.binaryNotFound
        }

        let tarball = try await fetch(url)
        guard Self.sha256Hex(of: tarball) == digests.tarballSHA256 else {
            Self.logger.error("Copilot language server download does not match its pinned digest, refusing to install")
            throw CopilotError.binaryNotFound
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let staging = baseDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("download.tgz")
        try tarball.write(to: archive)
        try await Self.extractBinary(from: archive, into: staging)

        let extracted = staging.appendingPathComponent("copilot-language-server")
        guard DownloadedBinary.sha256Hex(ofFileAt: extracted.path) == digests.binarySHA256 else {
            Self.logger.error("Extracted Copilot language server does not match its pinned digest, refusing to install")
            throw CopilotError.binaryNotFound
        }

        if fileManager.fileExists(atPath: binaryExecutablePath) {
            try fileManager.removeItem(atPath: binaryExecutablePath)
        }
        try fileManager.moveItem(atPath: extracted.path, toPath: binaryExecutablePath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryExecutablePath)
        DownloadedBinary.stripQuarantine(at: URL(fileURLWithPath: binaryExecutablePath))

        try Self.pinnedVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        Self.logger.info("Installed Copilot language server \(Self.pinnedVersion, privacy: .public)")
    }

    private static func extractBinary(from archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "xzf", archive.path, "-C", directory.path, "--strip-components=1", "package/copilot-language-server"
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CopilotError.binaryNotFound)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var versionFile: URL {
        baseDirectory.appendingPathComponent("version.txt")
    }

    private var binaryExecutablePath: String {
        baseDirectory.appendingPathComponent("copilot-language-server").path
    }

    static var platform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }
}
