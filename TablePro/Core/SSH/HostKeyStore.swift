//
//  HostKeyStore.swift
//  TablePro
//
//  Manages SSH host key verification for known hosts.
//  Stores trusted host keys in a line-based file at
//  ~/Library/Application Support/TablePro/known_hosts
//

import CryptoKit
import Foundation
import os

/// Manages SSH host key verification for known hosts
internal final class HostKeyStore: @unchecked Sendable {
    static let shared = HostKeyStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "HostKeyStore")

    enum VerificationResult: Equatable {
        case trusted
        case unknown(fingerprint: String, keyType: String)
        case mismatch(expected: String, actual: String)
    }

    private let filePath: String
    private let lock = NSLock()

    private init() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            self.filePath = NSTemporaryDirectory() + "TablePro_known_hosts"
            return
        }
        let tableProDir = appSupport.appendingPathComponent("TablePro")
        try? FileManager.default.createDirectory(at: tableProDir, withIntermediateDirectories: true)
        self.filePath = tableProDir.appendingPathComponent("known_hosts").path
    }

    /// Testing initializer with a custom file path
    init(filePath: String) {
        self.filePath = filePath
    }

    // MARK: - Public API

    /// Verify a host key against the known_hosts store
    /// - Parameters:
    ///   - keyData: The raw host key bytes
    ///   - keyType: The key type string (e.g. "ssh-rsa", "ssh-ed25519")
    ///   - hostname: The remote hostname
    ///   - port: The remote port
    /// - Returns: The verification result
    func verify(keyData: Data, keyType: String, hostname: String, port: Int) -> VerificationResult {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        let currentFingerprint = Self.fingerprint(of: keyData)
        let entries = loadEntries()

        guard let existing = entries.first(where: { $0.host == hostKey && $0.keyType == keyType }) else {
            Self.logger.info("Unknown host key for \(hostKey)")
            return .unknown(fingerprint: currentFingerprint, keyType: keyType)
        }

        let storedFingerprint = Self.fingerprint(of: existing.keyData)
        if storedFingerprint == currentFingerprint {
            Self.logger.debug("Host key trusted for \(hostKey)")
            return .trusted
        }

        Self.logger.warning("Host key mismatch for \(hostKey)")
        return .mismatch(expected: storedFingerprint, actual: currentFingerprint)
    }

    /// Add or update a trusted host key
    /// - Parameters:
    ///   - hostname: The remote hostname
    ///   - port: The remote port
    ///   - key: The raw host key bytes
    ///   - keyType: The key type string
    func trust(hostname: String, port: Int, key: Data, keyType: String) {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        var entries = loadEntries()

        // Remove existing entry for this host and key type if present
        entries.removeAll { $0.host == hostKey && $0.keyType == keyType }

        entries.append((host: hostKey, keyType: keyType, keyData: key))
        saveEntries(entries)

        Self.logger.info("Trusted host key for \(hostKey) (\(keyType))")
    }

    /// Remove a stored host key
    /// - Parameters:
    ///   - hostname: The remote hostname
    ///   - port: The remote port
    func remove(hostname: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        var entries = loadEntries()

        let countBefore = entries.count
        entries.removeAll { $0.host == hostKey }

        if entries.count < countBefore {
            saveEntries(entries)
            Self.logger.info("Removed host key for \(hostKey)")
        }
    }

    // MARK: - Key Type Mapping

    /// Convert a numeric key type to its string name
    static func keyTypeName(_ type: Int32) -> String {
        switch type {
        case 1: return "ssh-rsa"
        case 2: return "ssh-dss"
        case 3: return "ecdsa-sha2-nistp256"
        case 4: return "ecdsa-sha2-nistp384"
        case 5: return "ecdsa-sha2-nistp521"
        case 6: return "ssh-ed25519"
        default: return "unknown"
        }
    }

    // MARK: - Fingerprint

    /// Compute a SHA-256 fingerprint of a host key
    /// - Parameter key: The raw key bytes
    /// - Returns: Fingerprint in "SHA256:base64" format (matches ssh-keygen -l output)
    static func fingerprint(of key: Data) -> String {
        let hash = SHA256.hash(data: key)
        let base64 = Data(hash).base64EncodedString()
        // Remove trailing '=' padding to match OpenSSH format
        let trimmed = base64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(trimmed)"
    }

    // MARK: - Private Helpers

    /// Build the host identifier string: [hostname]:port
    private func hostIdentifier(_ hostname: String, _ port: Int) -> String {
        "[\(hostname)]:\(port)"
    }

    /// Load all entries from the known_hosts file
    /// File format: [hostname]:port keyType base64EncodedKey
    private func loadEntries() -> [(host: String, keyType: String, keyData: Data)] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return []
        }

        var entries: [(host: String, keyType: String, keyData: Data)] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let parts = trimmed.components(separatedBy: " ")
            guard parts.count == 3,
                  let keyData = Data(base64Encoded: parts[2]) else {
                Self.logger.warning("Skipping malformed known_hosts line: \(trimmed)")
                continue
            }

            entries.append((host: parts[0], keyType: parts[1], keyData: keyData))
        }

        return entries
    }

    /// Save entries to the known_hosts file
    private func saveEntries(_ entries: [(host: String, keyType: String, keyData: Data)]) {
        let lines = entries.map { entry in
            let base64Key = entry.keyData.base64EncodedString()
            return "\(entry.host) \(entry.keyType) \(base64Key)"
        }

        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to write known_hosts file: \(error.localizedDescription)")
        }
    }
}
