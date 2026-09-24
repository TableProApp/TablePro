import Foundation
import os
import SQLite3

extension SQLFavoriteStorage {
    private static let syncReadLogger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteSyncReads")

    func readAllFavorites() -> [SQLFavorite]? {
        readAllRows(
            "SELECT id, name, query, keyword, folder_id, connection_id, sort_order, created_at, updated_at FROM favorites;",
            parse: parseFavorite(from:)
        )
    }

    func readAllFolders() -> [SQLFavoriteFolder]? {
        readAllRows(
            "SELECT id, name, parent_id, connection_id, sort_order, created_at, updated_at FROM folders;",
            parse: parseFolder(from:)
        )
    }

    private func readAllRows<Row>(_ sql: String, parse: (OpaquePointer?) -> Row?) -> [Row]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            Self.syncReadLogger.error(
                "Saved queries could not be read: \(String(cString: sqlite3_errstr(prepareResult)), privacy: .public)"
            )
            return nil
        }

        var rows: [Row] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                if let row = parse(statement) {
                    rows.append(row)
                }
            case SQLITE_DONE:
                return rows
            default:
                Self.syncReadLogger.error(
                    "Saved queries could not be read: \(String(cString: sqlite3_errstr(stepResult)), privacy: .public)"
                )
                return nil
            }
        }
    }
}
