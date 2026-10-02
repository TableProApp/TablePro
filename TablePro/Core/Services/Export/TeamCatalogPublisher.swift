//
//  TeamCatalogPublisher.swift
//  TablePro
//
//  Publishes connection definitions to a shared team folder, without credentials.
//

import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamCatalogPublisher")

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
            removeEarlierFiles(of: connection, keeping: fileURL, in: folderURL)
            written.append(fileURL)
        }
        return written
    }

    static func filename(for connection: DatabaseConnection) -> String {
        let base = connection.name.isEmpty ? "connection" : connection.name
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = base.components(separatedBy: invalid).joined(separator: "-")
        let safeName = cleaned.isEmpty ? "connection" : cleaned
        return safeName + filenameSuffix(for: connection)
    }

    private static func filenameSuffix(for connection: DatabaseConnection) -> String {
        "-\(connection.id.uuidString.prefix(8)).tablepro"
    }

    private static func removeEarlierFiles(
        of connection: DatabaseConnection,
        keeping currentFile: URL,
        in folderURL: URL
    ) {
        let suffix = filenameSuffix(for: connection)
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileResourceIdentifierKey]
            )
        } catch {
            logger.warning("Could not list earlier catalog files: \(error.localizedDescription, privacy: .private)")
            return
        }
        for candidate in candidates where candidate.lastPathComponent.hasSuffix(suffix) {
            guard isRegularFile(candidate), !isSameFile(candidate, currentFile) else { continue }
            do {
                try FileManager.default.removeItem(at: candidate)
            } catch {
                logger.warning("Could not remove an earlier catalog file: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let lhsIdentity = try? lhs.resourceValues(forKeys: key).fileResourceIdentifier,
              let rhsIdentity = try? rhs.resourceValues(forKeys: key).fileResourceIdentifier else {
            return lhs.lastPathComponent.caseInsensitiveCompare(rhs.lastPathComponent) == .orderedSame
        }
        return lhsIdentity.isEqual(rhsIdentity)
    }
}
