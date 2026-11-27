import Foundation
import SQLite3

// What the core's history keeps of a run: the fields that sync (core ADR 0052, History).
internal struct CoreHistoryRow: Equatable, Sendable {
    let id: UUID
    let query: String
    let connectionId: UUID
    let databaseType: String
    let executedAt: Date
    let executionTime: TimeInterval
    let rowCount: Int
    let wasSuccessful: Bool
    let errorMessage: String?
    var databaseName = ""
    var schemaName: String?
    var source: QueryHistorySource?
    var statementType: QueryHistoryStatementType?
    var firstRowTime: TimeInterval?
    var serverTime: TimeInterval?
    // The statement's shape as this build's grammar reads it; 0 when it was never read.
    var shapeHash: Int64 = 0
}

internal extension QueryHistoryStorage {
    // Nil when the store is closed, so a missing store never reads as an empty one.
    func entryIds() -> Set<UUID>? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM history;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare entry ids")
            return nil
        }
        var ids: Set<UUID> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) {
                    ids.insert(id)
                }
            case SQLITE_DONE:
                return ids
            default:
                logSqliteError(context: "entry ids")
                return nil
            }
        }
    }

    func coreRows(ids: [UUID]) -> [CoreHistoryRow] {
        guard let db, !ids.isEmpty else { return [] }
        let sql = """
            SELECT id, query, connection_id, database_type, executed_at, execution_time, row_count,
                   was_successful, error_message, database_name, schema_name, source, statement_type,
                   first_row_time, server_time, shape_hash
            FROM history WHERE id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")));
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare core rows")
            return []
        }
        for (offset, id) in ids.enumerated() {
            QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: Int32(offset + 1))
        }
        var rows: [CoreHistoryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let query = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let connectionText = sqlite3_column_text(statement, 2),
                  let connectionId = UUID(uuidString: String(cString: connectionText))
            else { continue }
            rows.append(CoreHistoryRow(
                id: id,
                query: query,
                connectionId: connectionId,
                databaseType: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                executedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                executionTime: sqlite3_column_double(statement, 5),
                rowCount: Int(sqlite3_column_int64(statement, 6)),
                wasSuccessful: sqlite3_column_int(statement, 7) != 0,
                errorMessage: sqlite3_column_text(statement, 8).map { String(cString: $0) },
                databaseName: sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? "",
                schemaName: sqlite3_column_text(statement, 10).map { String(cString: $0) },
                source: sqlite3_column_text(statement, 11).flatMap { QueryHistorySource(rawValue: String(cString: $0)) },
                statementType: sqlite3_column_text(statement, 12)
                    .flatMap { QueryHistoryStatementType(rawValue: String(cString: $0)) },
                firstRowTime: Self.optionalDouble(statement, 13),
                serverTime: Self.optionalDouble(statement, 14),
                shapeHash: sqlite3_column_int64(statement, 15)
            ))
        }
        return rows
    }

    private static func optionalDouble(_ statement: OpaquePointer?, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    // The runs this store and the core's copy both held when they last agreed. It lives in this file, so a damaged
    // file set aside takes it along and the core keeps what it holds; the previous stable never touches it, so a run
    // it deleted shows as one that left. Nil when the store is closed.
    func coreMirrorBase() -> Set<UUID>? {
        guard let db, execute("CREATE TABLE IF NOT EXISTS core_mirror (id TEXT PRIMARY KEY) WITHOUT ROWID;") else {
            return nil
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM core_mirror;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare core mirror base")
            return nil
        }
        var ids: Set<UUID> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) {
                    ids.insert(id)
                }
            case SQLITE_DONE:
                return ids
            default:
                logSqliteError(context: "core mirror base")
                return nil
            }
        }
    }

    @discardableResult
    func updateCoreMirrorBase(adding added: Set<UUID>, removing removed: Set<UUID>) -> Bool {
        guard let db, !added.isEmpty || !removed.isEmpty,
              execute("CREATE TABLE IF NOT EXISTS core_mirror (id TEXT PRIMARY KEY) WITHOUT ROWID;"),
              execute("BEGIN IMMEDIATE;")
        else { return added.isEmpty && removed.isEmpty }
        let written = Self.each(added, in: db, "INSERT OR IGNORE INTO core_mirror (id) VALUES (?);")
            && Self.each(removed, in: db, "DELETE FROM core_mirror WHERE id = ?;")
        guard written, execute("COMMIT;") else {
            execute("ROLLBACK;")
            return false
        }
        return true
    }

    // The runs the person deleted here that the core may still hold, noted before each leaves this store, so a core
    // that cannot be reached now still gets the deletion, with its tombstone, on a later push. Nil when the store is
    // closed.
    func pendingCoreDeletions() -> Set<UUID>? {
        guard let db, execute(Self.pendingTableSql) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM core_mirror_deleted;", -1, &statement, nil) == SQLITE_OK else {
            logSqliteError(context: "prepare pending core deletions")
            return nil
        }
        var ids: Set<UUID> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) {
                    ids.insert(id)
                }
            case SQLITE_DONE:
                return ids
            default:
                logSqliteError(context: "pending core deletions")
                return nil
            }
        }
    }

    @discardableResult
    func notePendingCoreDeletions(_ ids: Set<UUID>) -> Bool {
        writeEach(ids, creating: Self.pendingTableSql, "INSERT OR IGNORE INTO core_mirror_deleted (id) VALUES (?);")
    }

    @discardableResult
    func clearPendingCoreDeletions(_ ids: Set<UUID>) -> Bool {
        writeEach(ids, creating: Self.pendingTableSql, "DELETE FROM core_mirror_deleted WHERE id = ?;")
    }

    // Runs the core let go after both held them, as a deletion another device synced: they go here too, with no
    // deletion of this Mac's to send.
    @discardableResult
    func deleteRuns(_ ids: Set<UUID>) -> Bool {
        writeEach(ids, creating: nil, "DELETE FROM history WHERE id = ?;")
    }

    // Runs other devices recorded, in one commit, so Insights, Rewind and the previous stable see them. Returns the ids
    // it wrote; one this store already holds keeps its row.
    func takePulled(_ entries: [QueryHistoryEntry]) -> Set<UUID> {
        guard !entries.isEmpty, execute("BEGIN IMMEDIATE;") else { return [] }
        var taken: Set<UUID> = []
        for entry in entries where insertRow(entry, ignoringExisting: true) {
            taken.insert(entry.id)
        }
        guard execute("COMMIT;") else {
            execute("ROLLBACK;")
            return []
        }
        return taken
    }

    // Whether the runs mirrored before the core kept their details were filled in, once per store file.
    func coreDetailsFilled() -> Bool {
        guard let db, execute(Self.metaTableSql) else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM core_mirror_meta WHERE key = 'details_filled';", -1, &statement, nil)
            == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    @discardableResult
    func markCoreDetailsFilled() -> Bool {
        execute(Self.metaTableSql)
            && execute("INSERT OR IGNORE INTO core_mirror_meta (key, value) VALUES ('details_filled', '1');")
    }

    private static let pendingTableSql = "CREATE TABLE IF NOT EXISTS core_mirror_deleted (id TEXT PRIMARY KEY) WITHOUT ROWID;"
    private static let metaTableSql = "CREATE TABLE IF NOT EXISTS core_mirror_meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;"

    private func writeEach(_ ids: Set<UUID>, creating table: String?, _ sql: String) -> Bool {
        guard let db else { return false }
        guard !ids.isEmpty else { return true }
        if let table, !execute(table) { return false }
        guard execute("BEGIN IMMEDIATE;") else { return false }
        guard Self.each(ids, in: db, sql), execute("COMMIT;") else {
            execute("ROLLBACK;")
            return false
        }
        return true
    }

    private static func each(_ ids: Set<UUID>, in db: OpaquePointer, _ sql: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        for id in ids {
            sqlite3_reset(statement)
            QueryHistorySqlBinding.text(id.uuidString).bind(to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        }
        return true
    }
}
