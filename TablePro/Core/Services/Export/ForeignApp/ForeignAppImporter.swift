//
//  ForeignAppImporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import Security
import TableProImport
import UniformTypeIdentifiers

// MARK: - Protocol

protocol ForeignAppImporter {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    /// Canonical bundle identifier of the source app. Importers whose source
    /// app ships in multiple editions (e.g. DBeaver Community / Enterprise)
    /// should override `installedAppURL()` to look those up as well.
    var appBundleIdentifier: String { get }
    /// True when importing passwords reads the macOS keychain, which makes the
    /// system show a per-item access prompt. Importers that read passwords from
    /// a file (DBeaver, Beekeeper Studio) return false so no prompt is promised.
    var readsPasswordsFromKeychain: Bool { get }
    /// Non-nil for importers that read a user-selected export file instead of an
    /// installed app's on-disk store. The values are the content types the file
    /// picker filters to; the source picker presents a panel and hands the
    /// chosen URL to `setSelectedFile(_:)` before importing.
    var importFileTypes: [UTType]? { get }
    func installedAppURL() -> URL?
    /// Declared here (not only in the extension) so concrete overrides dispatch
    /// through `any ForeignAppImporter`. File-sourced importers return true
    /// regardless of whether a matching app is installed.
    func isAvailable() -> Bool
    func connectionCount() -> Int
    mutating func setSelectedFile(_ url: URL)
    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult
}

extension ForeignAppImporter {
    /// LaunchServices lookup for the source app. Returns the URL on disk if
    /// the app is registered with macOS, regardless of whether the user has
    /// opened it or created any data. Override to consider multiple editions.
    func installedAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
    }

    /// Convenience: true when the source app is installed.
    func isAvailable() -> Bool {
        installedAppURL() != nil
    }

    var importFileTypes: [UTType]? { nil }

    mutating func setSelectedFile(_ url: URL) {}
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
        DBeaverImporter(),
        DataGripImporter(),
        BeekeeperStudioImporter(),
        NavicatImporter()
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

typealias ForeignKeychainRead = (_ service: String, _ account: String) -> KeychainReadResult

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
