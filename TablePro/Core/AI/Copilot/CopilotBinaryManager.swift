//
//  CopilotBinaryManager.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

actor CopilotBinaryManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotBinary")
    static let shared = CopilotBinaryManager()

    private let baseDirectory: URL
    private var downloadTask: Task<Void, Error>?

    init(baseDirectory: URL? = nil) {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        self.baseDirectory = baseDirectory
            ?? appSupport.appendingPathComponent("TablePro/copilot-language-server", isDirectory: true)
    }

    /// Whether the installed binary still matches the digest recorded when it was extracted.
    ///
    /// This catches a truncated download, a half-finished extraction and a file left behind by a
    /// failed install, and it makes those reinstall instead of being executed.
    ///
    /// It is deliberately **not** an integrity control against a deliberate swap, and must not be
    /// described as one. `sha256.txt` sits in the same user-writable directory as the binary it
    /// attests to, so anything able to replace the binary can rewrite the digest in the same
    /// breath. A real control needs an attestation the app can pin, and npm has none to pin
    /// against: this package is fetched from the `latest` tag, so the version is whatever the
    /// registry served that day. Compare `CloudSQLProxyBinaryManager`, where the version and the
    /// checksum are both pinned in source and the check does carry weight.
    func installedBinaryIsIntact() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binaryExecutablePath) else { return false }

        guard let recorded = recordedDigest() else {
            Self.logger.info("Copilot language server has no recorded digest, reinstalling")
            return false
        }

        guard DownloadedBinary.sha256Hex(ofFileAt: binaryExecutablePath) == recorded else {
            Self.logger.error("Copilot language server does not match its recorded digest, reinstalling")
            return false
        }
        return true
    }

    func ensureBinary() async throws -> String {
        let path = binaryExecutablePath
        if installedBinaryIsIntact() {
            return path
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

        guard installedBinaryIsIntact() else {
            throw CopilotError.binaryNotFound
        }
        return path
    }

    private func downloadBinary() async throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let platform = self.platform
        let optionalDep = "@github/copilot-language-server-\(platform)"

        guard let registryURL = URL(string: "https://registry.npmjs.org/\(optionalDep)/latest") else {
            throw CopilotError.binaryNotFound
        }
        let (data, _) = try await URLSession.shared.data(from: registryURL)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dist = json["dist"] as? [String: Any],
              let tarballURLString = dist["tarball"] as? String,
              let tarballURL = URL(string: tarballURLString) else {
            throw CopilotError.binaryNotFound
        }

        let (tarballData, _) = try await URLSession.shared.data(from: tarballURL)

        guard let integrityValue = dist["integrity"] as? String else {
            Self.logger.error("No integrity hash in npm registry response")
            throw CopilotError.binaryNotFound
        }

        let actualHash = "sha512-" + tarballData.sha512Base64String()
        if actualHash != integrityValue {
            Self.logger.error("Binary integrity mismatch")
            throw CopilotError.binaryNotFound
        }

        let tempTar = baseDirectory.appendingPathComponent("download.tar.gz")
        try tarballData.write(to: tempTar)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", tempTar.path, "-C", baseDirectory.path, "--strip-components=1", "package/copilot-language-server"]

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

        try? FileManager.default.removeItem(at: tempTar)

        if !FileManager.default.fileExists(atPath: binaryExecutablePath) {
            let enumerator = FileManager.default.enumerator(at: baseDirectory, includingPropertiesForKeys: nil)
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.lastPathComponent == "copilot-language-server" {
                    let foundPath = fileURL.path
                    if foundPath != binaryExecutablePath {
                        try FileManager.default.moveItem(atPath: foundPath, toPath: binaryExecutablePath)
                        Self.logger.info("Moved binary from \(foundPath) to expected location")
                    }
                    break
                }
            }
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryExecutablePath
        )

        DownloadedBinary.stripQuarantine(at: URL(fileURLWithPath: binaryExecutablePath))

        guard let digest = DownloadedBinary.sha256Hex(ofFileAt: binaryExecutablePath) else {
            throw CopilotError.binaryNotFound
        }
        try digest.write(to: digestFile, atomically: true, encoding: .utf8)

        if let version = json["version"] as? String {
            try version.write(to: versionFile, atomically: true, encoding: .utf8)
            Self.logger.info("Installed Copilot language server version \(version, privacy: .public)")
        }

        Self.logger.info("Downloaded Copilot language server binary")
    }

    func installedVersion() -> String? {
        try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordedDigest() -> String? {
        try? String(contentsOf: digestFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var versionFile: URL {
        baseDirectory.appendingPathComponent("version.txt")
    }

    private var digestFile: URL {
        baseDirectory.appendingPathComponent("sha256.txt")
    }

    private var binaryExecutablePath: String {
        baseDirectory.appendingPathComponent("copilot-language-server").path
    }

    private var platform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }
}

private extension Data {
    func sha512Base64String() -> String {
        let digest = SHA512.hash(data: self)
        return Data(digest).base64EncodedString()
    }
}
