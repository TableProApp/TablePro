//
//  LinkedSQLIndex.swift
//  TablePro
//

import Foundation
import os
import SQLite3

internal actor LinkedSQLIndex {
    static let shared = LinkedSQLIndex()
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedSQLIndex")

    private var db: OpaquePointer?
    private let databaseURL: URL
    private let removeDatabaseOnDeinit: Bool

    init(
        databaseURL: URL = LinkedSQLIndex.defaultDatabaseURL(),
        removeDatabaseOnDeinit: Bool = false
    ) {
        self.databaseURL = databaseURL
        self.removeDatabaseOnDeinit = removeDatabaseOnDeinit
        setupDatabase()
    }

    static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("TablePro")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("linked_sql_index.db")
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
        if removeDatabaseOnDeinit {
            let path = databaseURL.path(percentEncoded: false)
            try? FileManager.default.removeItem(atPath: path)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    private func setupDatabase() {
        let dir = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = databaseURL.path(percentEncoded: false)
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            Self.logger.error("Error opening linked SQL index database")
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        execute("""
            CREATE TABLE IF NOT EXISTS linked_sql_files (
                folder_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                name TEXT NOT NULL,
                keyword TEXT,
                description TEXT,
                mtime REAL NOT NULL,
                file_size INTEGER NOT NULL,
                encoding TEXT NOT NULL DEFAULT 'utf-8',
                PRIMARY KEY (folder_id, relative_path)
            );
        """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_linked_keyword
            ON linked_sql_files(keyword) WHERE keyword IS NOT NULL;
        """)
        execute("""
            CREATE INDEX IF NOT EXISTS idx_linked_folder
            ON linked_sql_files(folder_id);
        """)
        ensureEncodingColumn()
    }

    private func ensureEncodingColumn() {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(linked_sql_files);", -1, &statement, nil) == SQLITE_OK else { return }
        var hasEncoding = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cName = sqlite3_column_text(statement, 1) {
                if String(cString: cName) == "encoding" {
                    hasEncoding = true
                    break
                }
            }
        }
        if !hasEncoding {
            execute("ALTER TABLE linked_sql_files ADD COLUMN encoding TEXT NOT NULL DEFAULT 'utf-8';")
        }
    }

    private func execute(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let result = sqlite3_step(statement)
            if result != SQLITE_DONE && result != SQLITE_ROW {
                Self.logger.error("sqlite3_step failed (\(result)): \(String(cString: sqlite3_errmsg(self.db)))")
            }
        } else {
            Self.logger.error("sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(self.db)))")
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Mutations

    func replaceAll(folderId: UUID, files: [IndexedFile], folderURL: URL) {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }

        let deleteSQL = "DELETE FROM linked_sql_files WHERE folder_id = ?;"
        var deleteStatement: OpaquePointer?
        let folderIdString = folderId.uuidString
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(deleteStatement, 1, folderIdString, -1, Self.transient)
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)

        let insertSQL = """
            INSERT INTO linked_sql_files
            (folder_id, relative_path, name, keyword, description, mtime, file_size, encoding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insertStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(insertStatement) }

        for file in files {
            sqlite3_reset(insertStatement)
            sqlite3_bind_text(insertStatement, 1, folderIdString, -1, Self.transient)
            sqlite3_bind_text(insertStatement, 2, file.relativePath, -1, Self.transient)
            sqlite3_bind_text(insertStatement, 3, file.name, -1, Self.transient)
            if let keyword = file.keyword {
                sqlite3_bind_text(insertStatement, 4, keyword, -1, Self.transient)
            } else {
                sqlite3_bind_null(insertStatement, 4)
            }
            if let description = file.description {
                sqlite3_bind_text(insertStatement, 5, description, -1, Self.transient)
            } else {
                sqlite3_bind_null(insertStatement, 5)
            }
            sqlite3_bind_double(insertStatement, 6, file.mtime.timeIntervalSince1970)
            sqlite3_bind_int64(insertStatement, 7, file.fileSize)
            sqlite3_bind_text(insertStatement, 8, file.encoding.ianaName, -1, Self.transient)

            if sqlite3_step(insertStatement) != SQLITE_DONE {
                Self.logger.error("Failed to insert linked file: \(String(cString: sqlite3_errmsg(self.db)))")
            }
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func allFolderIds() -> Set<UUID> {
        let sql = "SELECT DISTINCT folder_id FROM linked_sql_files;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var ids: Set<UUID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(cString: cString)) {
                ids.insert(id)
            }
        }
        return ids
    }

    func removeFolder(folderId: UUID) {
        let sql = "DELETE FROM linked_sql_files WHERE folder_id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Queries

    func fetchAll(folderId: UUID, folderURL: URL) -> [LinkedSQLFavorite] {
        let sql = """
            SELECT relative_path, name, keyword, description, mtime, file_size, encoding
            FROM linked_sql_files
            WHERE folder_id = ?
            ORDER BY relative_path ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)

        var results: [LinkedSQLFavorite] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let relPath = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }
            let keyword = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let description = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let fileSize = sqlite3_column_int64(statement, 5)
            let encodingName = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "utf-8"

            results.append(LinkedSQLFavorite(
                folderId: folderId,
                fileURL: folderURL.appendingPathComponent(relPath),
                relativePath: relPath,
                name: name,
                keyword: keyword,
                fileDescription: description,
                mtime: mtime,
                fileSize: fileSize,
                encodingName: encodingName
            ))
        }
        return results
    }

    func fetchKeywordRows(folderIds: Set<UUID>) -> [(folderId: UUID, relativePath: String, keyword: String, name: String)] {
        guard !folderIds.isEmpty else { return [] }

        let placeholders = folderIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT folder_id, relative_path, keyword, name
            FROM linked_sql_files
            WHERE keyword IS NOT NULL AND folder_id IN (\(placeholders));
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        for (index, folderId) in folderIds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), folderId.uuidString, -1, Self.transient)
        }

        var results: [(folderId: UUID, relativePath: String, keyword: String, name: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let folderIdStr = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let folderId = UUID(uuidString: folderIdStr),
                  let relPath = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let keyword = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
                  let name = sqlite3_column_text(statement, 3).map({ String(cString: $0) }) else {
                continue
            }
            results.append((folderId, relPath, keyword, name))
        }
        return results
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

internal extension LinkedSQLIndex {
    struct IndexedFile {
        let relativePath: String
        let name: String
        let keyword: String?
        let description: String?
        let mtime: Date
        let fileSize: Int64
        let encoding: String.Encoding
    }
}
