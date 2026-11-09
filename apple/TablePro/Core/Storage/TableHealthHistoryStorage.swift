import Foundation
import os

enum TableHealthHistoryStorageError: LocalizedError {
    case readFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let reason):
            return String(format: String(localized: "TablePro could not read the Table Health history: %@"), reason)
        case .saveFailed(let reason):
            return String(format: String(localized: "TablePro could not save the Table Health history: %@"), reason)
        }
    }
}

// Nothing is cached, so every window and the MCP tool read what the last write left on disk.
@MainActor
final class TableHealthHistoryStorage: TableHealthHistoryStoring, TableScopedSettingsStore {
    static let shared = TableHealthHistoryStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TableHealthHistoryStorage")

    // An object rather than a bare map of databases, so a later build can add a field beside them.
    private struct Document: Codable {
        var databases: [String: TableHealthLedger] = [:]
    }

    private let directory: URL
    private let notificationCenter: NotificationCenter

    init(
        directory: URL = AppStorageEnvironment.shared.supportDirectory
            .appendingPathComponent("TableHealth", isDirectory: true),
        notificationCenter: NotificationCenter = .default
    ) {
        self.directory = directory
        self.notificationCenter = notificationCenter
    }

    func ledger(connectionId: UUID, database: String) throws -> TableHealthLedger {
        try load(connectionId).databases[database] ?? TableHealthLedger()
    }

    func record(
        _ report: TableHealthReport,
        connectionId: UUID,
        database: String,
        at date: Date
    ) throws -> TableHealthLedger {
        try mutate(connectionId: connectionId, database: database) { $0.recording(report, at: date) }
    }

    func setIgnored(
        _ ids: Set<TableHealthFindingID>,
        ignored: Bool,
        connectionId: UUID,
        database: String,
        at date: Date
    ) throws -> TableHealthLedger {
        try mutate(connectionId: connectionId, database: database) { ledger in
            ignored ? ledger.ignoring(ids, at: date) : ledger.unignoring(ids)
        }
    }

    func clearResolved(connectionId: UUID, database: String) throws -> TableHealthLedger {
        try mutate(connectionId: connectionId, database: database) { $0.clearingResolved() }
    }

    // Engines without a schema level (MySQL) store findings with a nil schema, which is what their scopes carry.
    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        guard let database = oldScope.database,
              oldScope.connectionId == newScope.connectionId,
              newScope.database == database,
              newScope.schema == oldScope.schema,
              newScope.table != oldScope.table
        else { return }
        mutateLogging(connectionId: oldScope.connectionId, database: database) {
            $0.renamingTable(schema: oldScope.schema, from: oldScope.table, to: newScope.table)
        }
    }

    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        if let fromSchema {
            guard let toSchema, fromDatabase == toDatabase, fromSchema != toSchema else { return }
            mutateLogging(connectionId: connectionId, database: fromDatabase) {
                $0.renamingSchema(from: fromSchema, to: toSchema)
            }
            return
        }
        guard fromDatabase != toDatabase else { return }
        do {
            var document = try load(connectionId)
            guard let moving = document.databases.removeValue(forKey: fromDatabase) else { return }
            // The renamed database takes the name, so a ledger left under it describes objects that are gone.
            document.databases[toDatabase] = moving
            try save(document, for: connectionId)
            postChange(connectionId: connectionId, databases: [fromDatabase, toDatabase])
        } catch {
            Self.logFailure(error, connectionId: connectionId)
        }
    }

    func dropTable(_ scope: TableScope) {
        guard let database = scope.database else { return }
        mutateLogging(connectionId: scope.connectionId, database: database) {
            $0.droppingTable(schema: scope.schema, name: scope.table)
        }
    }

    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        if let schema {
            mutateLogging(connectionId: connectionId, database: database) { $0.droppingSchema(schema) }
            return
        }
        do {
            var document = try load(connectionId)
            guard document.databases.removeValue(forKey: database) != nil else { return }
            try save(document, for: connectionId)
            postChange(connectionId: connectionId, databases: [database])
        } catch {
            Self.logFailure(error, connectionId: connectionId)
        }
    }

    // Device-local, so there is never a tombstone to leave.
    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        for connectionId in connectionIds {
            let databases = (try? load(connectionId))?.databases.keys.sorted() ?? []
            for url in storedFiles(for: connectionId) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Self.logger.error(
                        "Failed to remove Table Health history for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public)"
                    )
                }
            }
            postChange(connectionId: connectionId, databases: databases)
        }
    }

    private func mutate(
        connectionId: UUID,
        database: String,
        _ change: (TableHealthLedger) -> TableHealthLedger
    ) throws -> TableHealthLedger {
        var document = try load(connectionId)
        let current = document.databases[database] ?? TableHealthLedger()
        let next = change(current)
        guard next != current else { return next }
        document.databases[database] = next
        try save(document, for: connectionId)
        postChange(connectionId: connectionId, databases: [database])
        return next
    }

    private func mutateLogging(
        connectionId: UUID,
        database: String,
        _ change: (TableHealthLedger) -> TableHealthLedger
    ) {
        do {
            _ = try mutate(connectionId: connectionId, database: database, change)
        } catch {
            Self.logFailure(error, connectionId: connectionId)
        }
    }

    private func load(_ connectionId: UUID) throws -> Document {
        let url = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Self.logger.error(
                "Failed to read Table Health history for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            throw TableHealthHistoryStorageError.readFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch {
            Self.logger.error(
                "Unreadable Table Health history for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            try setAside(url, connectionId: connectionId)
            return Document()
        }
    }

    // A file this build cannot decode may be a newer build's, so it is kept under a free name and never written over.
    private func setAside(_ url: URL, connectionId: UUID) throws {
        var number = 1
        while FileManager.default.fileExists(atPath: corruptFileURL(for: connectionId, number: number).path) {
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: corruptFileURL(for: connectionId, number: number))
        } catch {
            Self.logger.error(
                "Failed to set aside unreadable Table Health history for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            throw TableHealthHistoryStorageError.readFailed(error.localizedDescription)
        }
    }

    private func save(_ document: Document, for connectionId: UUID) throws {
        let url = fileURL(for: connectionId)
        do {
            guard !document.databases.isEmpty else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
        } catch {
            Self.logger.error(
                "Failed to save Table Health history for \(connectionId, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            throw TableHealthHistoryStorageError.saveFailed(error.localizedDescription)
        }
    }

    private func storedFiles(for connectionId: UUID) -> [URL] {
        let name = connectionId.uuidString
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { url in
            let file = url.lastPathComponent
            return file == "\(name).json" || (file.hasPrefix("\(name).corrupt-") && file.hasSuffix(".json"))
        }
    }

    private func fileURL(for connectionId: UUID) -> URL {
        directory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private func corruptFileURL(for connectionId: UUID, number: Int) -> URL {
        directory.appendingPathComponent("\(connectionId.uuidString).corrupt-\(number).json")
    }

    private func postChange(connectionId: UUID, databases: [String]) {
        for database in Set(databases) {
            notificationCenter.post(
                name: .tableHealthHistoryDidChange,
                object: self,
                userInfo: TableHealthHistoryChange.userInfo(connectionId: connectionId, database: database)
            )
        }
    }

    private static func logFailure(_ error: any Error, connectionId: UUID) {
        logger.error(
            "Table Health history for \(connectionId, privacy: .public) was left unchanged: \(error.publicLogShape, privacy: .public)"
        )
    }
}
