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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        baseDirectory = appSupport.appendingPathComponent("TablePro/copilot-language-server", isDirectory: true)
    }

    func ensureBinary() async throws -> String {
        let path = binaryExecutablePath
        if FileManager.default.isExecutableFile(atPath: path) {
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

        guard FileManager.default.isExecutableFile(atPath: path) else {
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

        // Verify extraction; try to find binary if not at expected path
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

        // Store version for future reference
        if let version = json["version"] as? String {
            let versionFile = baseDirectory.appendingPathComponent("version.txt")
            try? version.write(to: versionFile, atomically: true, encoding: .utf8)
            Self.logger.info("Installed Copilot language server version \(version)")
        }

        Self.logger.info("Downloaded Copilot language server binary")
    }

    func installedVersion() -> String? {
        let versionFile = baseDirectory.appendingPathComponent("version.txt")
        return try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
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
