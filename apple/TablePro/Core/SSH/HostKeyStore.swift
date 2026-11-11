import CryptoKit
import Foundation
import os
import TableProSSHTransport

internal final class HostKeyStore: @unchecked Sendable {
    static let shared = HostKeyStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "HostKeyStore")

    enum VerificationResult: Equatable {
        case trusted
        case unknown(fingerprint: String, keyType: String)
        case mismatch(expected: String, actual: String)
        // The file is one entry per line split on spaces, so a host with a line break would plant
        // an entry for another host.
        case invalidHost(SSHDestinationName.Problem)
        // The saved keys could not be read, so a changed key would look like a new host.
        case unreadable
    }

    let filePath: String
    private let lock = NSLock()

    private init() {
        let tableProDir = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? FileManager.default.createDirectory(at: tableProDir, withIntermediateDirectories: true)
        self.filePath = tableProDir.appendingPathComponent("known_hosts").path
    }

    init(filePath: String) {
        self.filePath = filePath
    }

    func verify(keyData: Data, keyType: String, hostname: String, port: Int) -> VerificationResult {
        lock.lock()
        defer { lock.unlock() }

        guard let hostKey = hostIdentifier(hostname, port) else {
            return .invalidHost(.host(hostname))
        }
        guard let file = loadFile() else { return .unreadable }

        switch file.match(host: hostKey, keyType: keyType, keyData: keyData) {
        case .trusted:
            Self.logger.debug("Host key trusted for \(hostKey)")
            return .trusted
        case .unknown:
            Self.logger.info("Unknown host key for \(hostKey)")
            return .unknown(fingerprint: Self.fingerprint(of: keyData), keyType: keyType)
        case .changed(let storedKey):
            Self.logger.warning("Host key mismatch for \(hostKey)")
            return .mismatch(expected: Self.fingerprint(of: storedKey), actual: Self.fingerprint(of: keyData))
        case .unreadable:
            Self.logger.error("The saved host key for \(hostKey) could not be parsed")
            return .unreadable
        }
    }

    func trust(hostname: String, port: Int, key: Data, keyType: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let hostKey = hostIdentifier(hostname, port), var file = loadFile() else { return }
        file.trust(host: hostKey, keyType: keyType, keyData: key)
        saveFile(file)

        Self.logger.info("Trusted host key for \(hostKey) (\(keyType))")
    }

    func remove(hostname: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard let hostKey = hostIdentifier(hostname, port), var file = loadFile() else { return }
        if file.remove(host: hostKey) {
            saveFile(file)
            Self.logger.info("Removed host key for \(hostKey)")
        }
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

    // The OpenSSH form `ssh-keygen -l` prints: SHA-256, base64 without padding.
    static func fingerprint(of key: Data) -> String {
        let digest = SHA256.hash(data: key)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func hostIdentifier(_ hostname: String, _ port: Int) -> String? {
        guard SSHDestinationName.isValidHost(hostname) else {
            Self.logger.warning("Refusing a host key entry for a host ssh would refuse")
            return nil
        }
        return "[\(hostname)]:\(port)"
    }

    // nil means the file is there but unreadable, and nothing may be written over it.
    private func loadFile() -> KnownHostsFile? {
        do {
            return try KnownHostsFile.load(from: URL(fileURLWithPath: filePath))
        } catch {
            Self.logger.error("Failed to read known_hosts file: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveFile(_ file: KnownHostsFile) {
        do {
            try file.contents.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to write known_hosts file: \(error.localizedDescription)")
        }
    }
}
