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

// MARK: - Request, Inventory, Support

struct ForeignImportRequest: Sendable, Equatable {
    var includePasswords: Bool
    var includeSavedQueries: Bool
}

struct ForeignAppInventory: Sendable, Equatable {
    let connections: Int
    let savedQueries: Int
    // Upper bound of the Keychain items a read with passwords asks for; macOS prompts once per item that exists.
    let keychainPrompts: Int

    init(connections: Int, savedQueries: Int, keychainPrompts: Int = 0) {
        self.connections = connections
        self.savedQueries = savedQueries
        self.keychainPrompts = keychainPrompts
    }

    static let empty = ForeignAppInventory(connections: 0, savedQueries: 0)
}

enum ForeignSavedQuerySupport: Sendable, Equatable {
    case reads(caption: String)
    case unavailable(reason: String)

    static func globalFolder(named appName: String) -> ForeignSavedQuerySupport {
        .reads(caption: String(
            format: String(localized: "Saved queries import for every connection, in a folder named “%@”."),
            appName
        ))
    }
}

// MARK: - Protocol

protocol ForeignAppImporter: Sendable {
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    // An app shipped in several editions overrides `installedAppURL()` to look each one up.
    var appBundleIdentifier: String { get }
    // True when reading passwords makes macOS show a Keychain prompt per item.
    var readsPasswordsFromKeychain: Bool { get }
    // Non-nil when the importer reads a file the user picks rather than the app's own store.
    var importFileTypes: [UTType]? { get }
    var savedQuerySupport: ForeignSavedQuerySupport { get }
    func installedAppURL() -> URL?
    // The launch probe runs it, so it looks only in the app's own ~/Library folder, where no privacy prompt fires.
    func hasDataAtDefaultLocation() -> Bool
    // True when `isAvailable()` or `inventory()` can reach a folder macOS guards with a prompt; a scan nobody clicked skips both.
    var readsGuardedLocations: Bool { get }
    // Declared here so an override dispatches through `any ForeignAppImporter`.
    func isAvailable() -> Bool
    // Files only, never the Keychain; data that is there but unreadable throws, so it never reads as zero.
    func inventory() throws -> ForeignAppInventory
    mutating func setSelectedFile(_ url: URL)
    func collect(_ request: ForeignImportRequest) throws -> CollectedImport
}

extension ForeignAppImporter {
    func installedAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
    }

    // A deleted app leaves its data behind, and that data still imports.
    func isAvailable() -> Bool {
        installedAppURL() != nil || hasDataAtDefaultLocation()
    }

    var importFileTypes: [UTType]? { nil }

    // A file the user picks may come from someone else, so its connections never open on their own.
    var importOrigin: ImportOrigin {
        importFileTypes == nil ? .ownMachineOrAccount : .fileOrLink
    }

    var readsGuardedLocations: Bool { false }

    mutating func setSelectedFile(_ url: URL) {}
}

// MARK: - Records

struct ForeignConnectionRecord: Sendable {
    let sourceId: String?
    let settings: ExportableConnection
    let groupPath: [String]
    let credentials: ExportableCredentials?
    // Shown on the review row only: foreign imports skip sanitizedForImport, so a field would be saved.
    var notes: [String] = []
}

enum ForeignImportNote {
    static func tlsFromDriverDefault(_ mode: SSLMode, appName: String) -> String {
        String(
            format: String(localized: "SSL %1$@ is on because %2$@ encrypts this connection by default"),
            mode.displayLabel,
            appName
        )
    }
}

struct ForeignSavedQuery: Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case text(String)
        case oversized(byteCount: Int)
    }

    let name: String
    let content: Content
    let keyword: String?
    let folderPath: [String]
    let sourceConnectionId: String?
    let isAutoNamed: Bool
}

// MARK: - Database Types

enum ForeignAppDatabaseType {
    static func resolve(_ identifier: String) -> String {
        ConnectionTypeResolver.canonicalTypeId(
            identifier,
            registeredTypeIds: Set(PluginMetadataRegistry.shared.allRegisteredTypeIds())
        ) ?? identifier
    }

    static func defaultPort(for typeId: String) -> Int {
        DatabaseType(rawValue: typeId).defaultPort
    }

    static func localFilePathField(for typeId: String) -> LocalFilePathField? {
        PluginMetadataRegistry.shared.snapshot(for: DatabaseType(rawValue: typeId))?.capabilities.localFilePathField
    }
}

// MARK: - Error

enum ForeignAppImportError: LocalizedError {
    case fileNotFound(String)
    case parseError(String)
    case unsupportedFormat(String)
    case noConnectionsFound
    case unreadable(String)

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
        case .unreadable(let reason):
            return reason
        }
    }

    static func unreadableFile(_ url: URL) -> ForeignAppImportError {
        .unreadable(String(format: String(localized: "%@ could not be read."), url.lastPathComponent))
    }
}

enum ForeignAppStoredFile {
    // Nil when the file is not there; a file that is there and cannot be read throws `unreadable`.
    static func data(at url: URL, read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Data? {
        do {
            return try read(url)
        } catch {
            if ForeignAppFile.isMissing(error) || (error as? CocoaError)?.code == .fileReadNoSuchFile {
                return nil
            }
            throw ForeignAppImportError.unreadableFile(url)
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

typealias ForeignKeychainRead = @Sendable (_ service: String, _ account: String) -> KeychainReadResult

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
            logger.debug("Keychain read denied or cancelled: \(status)")
            return .cancelled
        }
    }
}
