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

    private struct DatabaseHandle: @unchecked Sendable {
        var pointer: OpaquePointer?
    }

    private var dbHandle = DatabaseHandle()

    private let databaseURL: URL
    private let removeDatabaseOnDeinit: Bool
    private var isPrepared = false

    private var db: OpaquePointer? {
        if !isPrepared {
            isPrepared = true
            setupDatabase()
        }
        return dbHandle.pointer
    }

    init(
        databaseURL: URL = LinkedSQLIndex.defaultDatabaseURL(),
        removeDatabaseOnDeinit: Bool = false
    ) {
        self.databaseURL = databaseURL
        self.removeDatabaseOnDeinit = removeDatabaseOnDeinit
    }

    static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let dir = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("linked_sql_index.db")
    }

    deinit {
        if let pointer = dbHandle.pointer {
            sqlite3_close_v2(pointer)
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

        guard case .opened(let pointer, let setAside) = LocalSQLiteStoreOpener.open(at: databaseURL) else {
            Self.logger.error("Error opening linked SQL index database")
            return
        }
        dbHandle.pointer = pointer
        // Only a cache of the linked files, which the next folder scan rebuilds, so no damaged copy is kept.
        if setAside != nil {
            LocalSQLiteStoreOpener.removeSetAsideCopies(of: databaseURL)
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

    // Writes only what differs from the stored rows, in one transaction, and returns whether any row changed.
    @discardableResult
    func synchronize(folderId: UUID, files: [IndexedFile]) -> Bool {
        let stored = storedFiles(folderId: folderId)
        let listed = Dictionary(files.map { ($0.relativePath, $0) }, uniquingKeysWith: { _, last in last })
        let removed = stored.keys.filter { listed[$0] == nil }.sorted()
        let changed = listed.values.filter { stored[$0.relativePath] != $0 }.sorted { $0.relativePath < $1.relativePath }
        guard !removed.isEmpty || !changed.isEmpty else { return false }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            Self.logger.error("Could not begin a linked SQL index write: \(String(cString: sqlite3_errmsg(self.db)))")
            return false
        }
        guard deleteRows(folderId: folderId, relativePaths: removed), upsertRows(folderId: folderId, files: changed) else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            Self.logger.error("Could not commit a linked SQL index write: \(String(cString: sqlite3_errmsg(self.db)))")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    private func deleteRows(folderId: UUID, relativePaths: [String]) -> Bool {
        guard !relativePaths.isEmpty else { return true }
        let sql = "DELETE FROM linked_sql_files WHERE folder_id = ? AND relative_path = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        for relativePath in relativePaths {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, relativePath, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Self.logger.error("Failed to delete a linked file: \(String(cString: sqlite3_errmsg(self.db)))")
                return false
            }
        }
        return true
    }

    private func upsertRows(folderId: UUID, files: [IndexedFile]) -> Bool {
        guard !files.isEmpty else { return true }
        let sql = """
            INSERT INTO linked_sql_files
            (folder_id, relative_path, name, keyword, description, mtime, file_size, encoding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(folder_id, relative_path) DO UPDATE SET
                name = excluded.name,
                keyword = excluded.keyword,
                description = excluded.description,
                mtime = excluded.mtime,
                file_size = excluded.file_size,
                encoding = excluded.encoding;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        for file in files {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, file.relativePath, -1, Self.transient)
            sqlite3_bind_text(statement, 3, file.name, -1, Self.transient)
            bindOptionalText(statement, 4, file.keyword)
            bindOptionalText(statement, 5, file.description)
            sqlite3_bind_double(statement, 6, file.mtime)
            sqlite3_bind_int64(statement, 7, file.fileSize)
            sqlite3_bind_text(statement, 8, file.encodingName, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Self.logger.error("Failed to write a linked file: \(String(cString: sqlite3_errmsg(self.db)))")
                return false
            }
        }
        return true
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func storedFiles(folderId: UUID) -> [String: IndexedFile] {
        let sql = """
            SELECT relative_path, name, keyword, description, mtime, file_size, encoding
            FROM linked_sql_files
            WHERE folder_id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)

        var files: [String: IndexedFile] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let relativePath = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }
            files[relativePath] = IndexedFile(
                relativePath: relativePath,
                name: name,
                keyword: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                description: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                mtime: sqlite3_column_double(statement, 4),
                fileSize: sqlite3_column_int64(statement, 5),
                encodingName: sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? "utf-8"
            )
        }
        return files
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

    // Returns whether the folder had any rows.
    @discardableResult
    func removeFolder(folderId: UUID) -> Bool {
        let sql = "DELETE FROM linked_sql_files WHERE folder_id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, folderId.uuidString, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
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
    struct IndexedFile: Equatable, Sendable {
        let relativePath: String
        let name: String
        let keyword: String?
        let description: String?
        // Seconds since 1970 as the column stores them, so a row read back compares exactly.
        let mtime: TimeInterval
        let fileSize: Int64
        let encodingName: String
    }
}
