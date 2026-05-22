//
//  JetBrainsCredentialStore.swift
//  TablePro
//

import CommonCrypto
import Foundation
import os
import Security

/// Resolves JetBrains credentials. The IDE names each secret with
/// `generateServiceName(subsystem, key)`, formatted
/// `IntelliJ Platform <subsystem> \u{2014} <key>`:
/// - DB password: subsystem `DB`, key `<data-source uuid>`.
/// - SSH tunnel password: subsystem `SshConfigPassword`, key `<host>:<port> <ssh-config-id>`.
/// - SSH key passphrase: subsystem `SshConfigPassphrase`, same key shape.
///
/// SSH secrets only exist once a connection authenticated and saved them. On macOS
/// the secret lives in the native Keychain; only the "In KeePass" mode writes the
/// encrypted `c.kdbx`, so the Keychain is tried first and the KDBX is a fallback.
final class JetBrainsCredentialStore {
    enum Lookup {
        case found(String)
        case notFound
        case cancelled
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "JetBrainsCredentialStore")

    /// ASCII bytes of "Proxy Config Sec", the hardcoded AES-128 key the IDE uses
    /// for the BUILT_IN encryption of the KDBX main key in `c.pwd`.
    private static let builtInKey: [UInt8] = Array("Proxy Config Sec".utf8)

    private let configDir: URL
    private var kdbxEntriesByTitle: [String: KdbxEntry]?
    private var kdbxLoaded = false
    private var storeLocked = false

    init(configDir: URL) {
        self.configDir = configDir
    }

    static func serviceName(forDataSourceUUID uuid: String) -> String {
        "IntelliJ Platform DB \u{2014} \(uuid)"
    }

    static func sshPasswordServiceName(host: String, port: Int, configId: String) -> String {
        "IntelliJ Platform SshConfigPassword \u{2014} \(host):\(port) \(configId)"
    }

    static func sshPassphraseServiceName(host: String, port: Int, configId: String) -> String {
        "IntelliJ Platform SshConfigPassphrase \u{2014} \(host):\(port) \(configId)"
    }

    func password(forDataSourceUUID uuid: String) -> Lookup {
        secret(service: Self.serviceName(forDataSourceUUID: uuid))
    }

    func sshPassword(host: String, port: Int, configId: String) -> Lookup {
        secret(service: Self.sshPasswordServiceName(host: host, port: port, configId: configId))
    }

    func sshKeyPassphrase(host: String, port: Int, configId: String) -> Lookup {
        secret(service: Self.sshPassphraseServiceName(host: host, port: port, configId: configId))
    }

    private func secret(service: String) -> Lookup {
        switch readKeychain(service: service) {
        case .found(let value): return .found(value)
        case .cancelled: return .cancelled
        case .notFound: break
        }

        if let entry = loadKdbxEntries()?[service], !entry.password.isEmpty {
            return .found(entry.password)
        }
        return storeLocked ? .cancelled : .notFound
    }

    // MARK: - Keychain

    private func readKeychain(service: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .notFound
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            Self.logger.debug("Keychain read denied or cancelled for \(service): \(status)")
            return .cancelled
        }
    }

    // MARK: - KDBX

    private func loadKdbxEntries() -> [String: KdbxEntry]? {
        if kdbxLoaded { return kdbxEntriesByTitle }
        kdbxLoaded = true

        let kdbxURL = configDir.appendingPathComponent("c.kdbx")
        guard FileManager.default.fileExists(atPath: kdbxURL.path),
              let fileData = try? Data(contentsOf: kdbxURL),
              let mainKey = loadMainKey() else { return nil }

        do {
            let entries = try KdbxDatabase.read(fileData: fileData, mainKey: mainKey)
            kdbxEntriesByTitle = Dictionary(entries.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            Self.logger.warning("Failed to read c.kdbx: \(error.localizedDescription)")
        }
        return kdbxEntriesByTitle
    }

    private func loadMainKey() -> [UInt8]? {
        for fileName in ["c.pwd", "pdb.pwd"] {
            let url = configDir.appendingPathComponent(fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let parsed = parseMainKeyFile(text) else { continue }
            guard parsed.encryption == "BUILT_IN" else {
                Self.logger.warning("Unsupported c.pwd encryption: \(parsed.encryption)")
                storeLocked = true
                continue
            }
            if let key = decryptBuiltIn(parsed.value) {
                return key
            }
        }
        return nil
    }

    private func parseMainKeyFile(_ text: String) -> (encryption: String, value: [UInt8])? {
        var encryption = "BUILT_IN"
        var base64Parts: [String] = []
        var capturingValue = false

        for line in text.components(separatedBy: .newlines) {
            if capturingValue {
                if let first = line.first, first == " " || first == "\t" {
                    base64Parts.append(line)
                    continue
                }
                capturingValue = false
            }
            if let range = line.range(of: "encryption:") {
                encryption = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: "value:") {
                let rest = String(line[range.upperBound...])
                    .replacingOccurrences(of: "!!binary", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest == "|" || rest == "|-" || rest == ">" {
                    capturingValue = true
                } else {
                    base64Parts.append(rest)
                }
            }
        }

        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let base64 = String(base64Parts.joined().filter { alphabet.contains($0) })
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (encryption, [UInt8](data))
    }

    private func decryptBuiltIn(_ blob: [UInt8]) -> [UInt8]? {
        guard blob.count > 4 else { return nil }
        let ivLength = Int(bigEndianUInt32(blob, 0))
        guard ivLength == kCCBlockSizeAES128, blob.count > 4 + ivLength else { return nil }
        let iv = Array(blob[4..<4 + ivLength])
        let ciphertext = Array(blob[(4 + ivLength)...])
        return aesCBCDecrypt(ciphertext, key: Self.builtInKey, iv: iv)
    }

    private func aesCBCDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            ciphertext,
            ciphertext.count,
            &output,
            output.count,
            &outputLength
        )
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(outputLength))
    }

    private func bigEndianUInt32(_ data: [UInt8], _ index: Int) -> UInt32 {
        (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }
}
