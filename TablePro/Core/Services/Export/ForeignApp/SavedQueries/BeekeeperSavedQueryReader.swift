//
//  BeekeeperSavedQueryReader.swift
//  TablePro
//

import Foundation
import SQLite3

enum BeekeeperSavedQueryReader {
    // Every install seeds this example, so importing it would add noise to every library.
    static let seededDemoTitle = "Demo Query"

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct Folder {
        let name: String
        let parentId: Int?
    }

    static func savedQueries(db: OpaquePointer?, limit: Int) throws -> [ForeignSavedQuery] {
        let columns = columnNames(of: "favorite_query", db: db)
        guard columns.contains("title"), columns.contains("text") else { return [] }

        let folders = columns.contains("queryFolderId") ? readFolders(db: db) : [:]
        let folderColumn = folders.isEmpty ? "NULL" : "queryFolderId"
        let sql = """
            SELECT title, CASE WHEN length(CAST(text AS BLOB)) > ? THEN NULL ELSE text END,
                   length(CAST(text AS BLOB)), \(folderColumn)
            FROM favorite_query
            \(whereClause(columns, []))
            ORDER BY id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(limit))

        var queries: [ForeignSavedQuery] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()
            let title = text(statement, 0) ?? ""
            guard title != seededDemoTitle else { continue }
            let byteCount = Int(sqlite3_column_int64(statement, 2))
            let content: ForeignSavedQuery.Content
            if byteCount > limit {
                content = .oversized(byteCount: byteCount)
            } else if let sql = text(statement, 1), !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = .text(sql)
            } else {
                continue
            }
            queries.append(ForeignSavedQuery(
                name: title,
                content: content,
                keyword: nil,
                folderPath: folderPath(of: int(statement, 3), in: folders),
                sourceConnectionId: nil,
                isAutoNamed: false
            ))
        }
        return queries
    }

    static func count(db: OpaquePointer?) -> Int {
        let columns = columnNames(of: "favorite_query", db: db)
        guard columns.contains("title"), columns.contains("text") else { return 0 }
        let conditions = ["title IS NOT ?", "trim(COALESCE(text, ''), ' ' || char(9) || char(10) || char(13)) != ''"]
        let sql = "SELECT COUNT(*) FROM favorite_query \(whereClause(columns, conditions))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, seededDemoTitle, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // Rows of a cloud workspace belong to that workspace's server copy, as for connections.
    private static func whereClause(_ columns: Set<String>, _ conditions: [String]) -> String {
        let all = (columns.contains("workspaceId") ? ["workspaceId = -1"] : []) + conditions
        return all.isEmpty ? "" : "WHERE " + all.joined(separator: " AND ")
    }

    private static func readFolders(db: OpaquePointer?) -> [Int: Folder] {
        let columns = columnNames(of: "query_folder", db: db)
        guard columns.contains("id"), columns.contains("name") else { return [:] }
        let parentColumn = columns.contains("parentId") ? "parentId" : "NULL"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, \(parentColumn) FROM query_folder", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var folders: [Int: Folder] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            folders[Int(sqlite3_column_int64(statement, 0))] = Folder(
                name: text(statement, 1) ?? "",
                parentId: int(statement, 2)
            )
        }
        return folders
    }

    private static func folderPath(of folderId: Int?, in folders: [Int: Folder]) -> [String] {
        var path: [String] = []
        var visited: Set<Int> = []
        var current = folderId
        while let id = current, visited.insert(id).inserted, let folder = folders[id] {
            path.insert(folder.name, at: 0)
            current = folder.parentId
        }
        return path
    }

    private static func columnNames(of table: String, db: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) {
                names.insert(name)
            }
        }
        return names
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}
