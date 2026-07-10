//
//  TeamCatalogPublisher.swift
//  TablePro
//
//  Publishes connection definitions to a shared team folder, without credentials.
//

import Foundation

enum TeamCatalogError: LocalizedError {
    case noConnections
    case notADirectory(URL)

    var errorDescription: String? {
        switch self {
        case .noConnections:
            return String(localized: "There are no connections to publish.")
        case .notADirectory(let url):
            return String(format: String(localized: "The catalog location is not a folder: %@"), url.path)
        }
    }
}

/// Writes secret-free connection definitions into a shared folder so teammates whose linked folders
/// point at the same location see them. Credentials are never written: the plaintext export envelope
/// already strips passwords, passphrases, TOTP secrets, and secure plugin fields.
@MainActor
internal enum TeamCatalogPublisher {
    @discardableResult
    static func publish(_ connections: [DatabaseConnection], to folderURL: URL) throws -> [URL] {
        guard !connections.isEmpty else { throw TeamCatalogError.noConnections }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TeamCatalogError.notADirectory(folderURL)
        }

        var written: [URL] = []
        for connection in connections {
            let data = try ConnectionExportService.exportData([connection])
            let fileURL = folderURL.appendingPathComponent(filename(for: connection))
            try data.write(to: fileURL, options: .atomic)
            written.append(fileURL)
        }
        return written
    }

    /// A stable, filesystem-safe filename keyed by connection id, so republishing updates the same file.
    static func filename(for connection: DatabaseConnection) -> String {
        let base = connection.name.isEmpty ? "connection" : connection.name
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = base.components(separatedBy: invalid).joined(separator: "-")
        let safeName = cleaned.isEmpty ? "connection" : cleaned
        let suffix = connection.id.uuidString.prefix(8)
        return "\(safeName)-\(suffix).tablepro"
    }
}
