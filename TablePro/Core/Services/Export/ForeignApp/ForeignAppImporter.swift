//
//  ForeignAppImporter.swift
//  TablePro
//

import Foundation
import os
import Security

// MARK: - Protocol

protocol ForeignAppImporter {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    var appBundleIdentifier: String { get }
    func isAvailable() -> Bool
    func connectionCount() -> Int
    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult
}

// MARK: - Result

struct ForeignAppImportResult {
    let envelope: ConnectionExportEnvelope
    let sourceName: String
    let credentialsAborted: Bool

    init(envelope: ConnectionExportEnvelope, sourceName: String, credentialsAborted: Bool = false) {
        self.envelope = envelope
        self.sourceName = sourceName
        self.credentialsAborted = credentialsAborted
    }
}

// MARK: - Error

enum ForeignAppImportError: LocalizedError {
    case fileNotFound(String)
    case parseError(String)
    case unsupportedFormat(String)
    case noConnectionsFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let app):
            return String(format: String(localized: "Could not find %@ data files"), app)
        case .parseError(let detail):
            return String(format: String(localized: "Failed to parse connections: %@"), detail)
        case .unsupportedFormat(let detail):
            return String(format: String(localized: "Unsupported file format: %@"), detail)
        case .noConnectionsFound:
            return String(localized: "No connections found to import")
        }
    }
}

// MARK: - Registry

enum ForeignAppImporterRegistry {
    static let all: [any ForeignAppImporter] = [
        TablePlusImporter(),
        SequelAceImporter(),
        DBeaverImporter()
    ]
}

// MARK: - Path Helpers

enum ForeignAppPathHelper {
    static func resolveKeyPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if path.hasPrefix("/") || path.hasPrefix("~/") { return path }
        return "~/.ssh/\(path)"
    }
}

// MARK: - Keychain Reader

enum KeychainReadResult {
    case found(String)
    case notFound
    case cancelled
}

enum ForeignKeychainReader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeychainReader")

    static func readPassword(service: String, account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .notFound
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            logger.debug("Keychain read denied or cancelled for \(service): \(status)")
            return .cancelled
        }
    }
}
