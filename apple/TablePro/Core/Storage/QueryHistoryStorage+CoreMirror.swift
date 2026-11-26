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
                   was_successful, error_message
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
                errorMessage: sqlite3_column_text(statement, 8).map { String(cString: $0) }
            ))
        }
        return rows
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
