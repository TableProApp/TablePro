//
//  HostKeyStore.swift
//  TableProMobile
//
//  Trusted SSH host keys, stored line-based in the app's Application Support
//  directory. Mirrors the Mac store's file format and verification semantics.
//

import CryptoKit
import Foundation
import os

nonisolated final class HostKeyStore: @unchecked Sendable {
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
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.filePath = appSupport.appendingPathComponent("known_hosts").path
    }

    init(filePath: String) {
        self.filePath = filePath
    }

    func verify(keyData: Data, keyType: String, hostname: String, port: Int) -> VerificationResult {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        let currentFingerprint = Self.fingerprint(of: keyData)
        let entries = loadEntries()

        let hostEntries = entries.filter { $0.host == hostKey }
        guard !hostEntries.isEmpty else {
            Self.logger.info("Unknown host key for \(hostKey)")
            return .unknown(fingerprint: currentFingerprint, keyType: keyType)
        }

        if hostEntries.contains(where: { Self.fingerprint(of: $0.keyData) == currentFingerprint }) {
            return .trusted
        }

        let sameType = hostEntries.first { $0.keyType == keyType }
        let storedFingerprint = Self.fingerprint(of: (sameType ?? hostEntries[0]).keyData)

        Self.logger.warning("Host key mismatch for \(hostKey)")
        return .mismatch(expected: storedFingerprint, actual: currentFingerprint)
    }

    func trust(hostname: String, port: Int, key: Data, keyType: String) {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        var entries = loadEntries()
        entries.removeAll { $0.host == hostKey && $0.keyType == keyType }
        entries.append((host: hostKey, keyType: keyType, keyData: key))
        saveEntries(entries)
    }

    func remove(hostname: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }

        let hostKey = hostIdentifier(hostname, port)
        var entries = loadEntries()
        entries.removeAll { $0.host == hostKey }
        saveEntries(entries)
    }

    func trustedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(loadEntries().map(\.host))).sorted()
    }

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

    static func fingerprint(of key: Data) -> String {
        let digest = SHA256.hash(data: key)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func hostIdentifier(_ hostname: String, _ port: Int) -> String {
        "[\(hostname)]:\(port)"
    }

    private func loadEntries() -> [(host: String, keyType: String, keyData: Data)] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return []
        }

        var entries: [(host: String, keyType: String, keyData: Data)] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.components(separatedBy: " ")
            guard parts.count == 3, let keyData = Data(base64Encoded: parts[2]) else {
                Self.logger.warning("Skipping malformed known_hosts line")
                continue
            }

            entries.append((host: parts[0], keyType: parts[1], keyData: keyData))
        }

        return entries
    }

    private func saveEntries(_ entries: [(host: String, keyType: String, keyData: Data)]) {
        let lines = entries.map { "\($0.host) \($0.keyType) \($0.keyData.base64EncodedString())" }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to write known_hosts file: \(error.localizedDescription)")
        }
    }
}
