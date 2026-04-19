//
//  SQLFavoriteStorage.swift
//  TablePro
//

import Foundation
import os
import SQLite3

/// Thread-safe SQLite storage for SQL favorites with FTS5 full-text search
internal final class SQLFavoriteStorage {
    static let shared = SQLFavoriteStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteStorage")

    private let queue = DispatchQueue(label: "com.TablePro.sqlfavorites", qos: .utility)
    private var db: OpaquePointer?

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private init() {
        queue.async { [weak self] in
            self?.setupDatabase()
        }
    }

    #if DEBUG
    /// Creates an isolated instance with a unique database file. For testing only.
    init(isolatedForTesting: Bool) {
        testDatabaseSuffix = isolatedForTesting ? "_\(UUID().uuidString)" : nil
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            setupDatabase()
            semaphore.signal()
        }
        semaphore.wait()
    }
    #endif

    private var testDatabaseSuffix: String?

    private var dbPath: String?

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
        if Self.isRunningTests, let dbPath = dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    // MARK: - Database Work Helpers

    private func performDatabaseWork<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performDatabaseWork<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = work()
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            Self.logger.error("Unable to access application support directory")
            return
        }
        let tableProDir = appSupport.appendingPathComponent("TablePro")

        try? fileManager.createDirectory(at: tableProDir, withIntermediateDirectories: true)

        let suffix = testDatabaseSuffix ?? ""
        let dbFileName = Self.isRunningTests
            ? "sql_favorites_test_\(ProcessInfo.processInfo.processIdentifier)\(suffix).db"
            : "sql_favorites.db"
        let dbPath = tableProDir.appendingPathComponent(dbFileName).path(percentEncoded: false)

        self.dbPath = dbPath

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            Self.logger.error("Error opening database")
            return
        }

        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        createTables()
        migrateIfNeeded()
    }

    // MARK: - Schema Migration

    private func migrateIfNeeded() {
        let currentVersion = getUserVersion()

        if currentVersion < 1 {
            // Fresh database — tables already created without is_synced, jump to latest version
            setUserVersion(2)
            return
        }

        if currentVersion < 2 {
            // Remove is_synced column using rename-recreate-copy pattern
            // (SQLite < 3.35.0 doesn't support ALTER TABLE DROP COLUMN)
            execute("ALTER TABLE favorites RENAME TO favorites_old")
            execute("""
                CREATE TABLE IF NOT EXISTS favorites (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL,
                    keyword TEXT, folder_id TEXT, connection_id TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
                )
            """)
            execute("""
                INSERT INTO favorites SELECT id, name, query, keyword, folder_id, connection_id,
                sort_order, created_at, updated_at FROM favorites_old
            """)
            execute("DROP TABLE favorites_old")

            execute("ALTER TABLE folders RENAME TO folders_old")
            execute("""
                CREATE TABLE IF NOT EXISTS folders (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
                )
            """)
            execute("""
                INSERT INTO folders SELECT id, name, parent_id, connection_id,
                sort_order, created_at, updated_at FROM folders_old
            """)
            execute("DROP TABLE folders_old")

            // Recreate indexes dropped with the old tables
            execute("CREATE INDEX IF NOT EXISTS idx_favorites_connection ON favorites(connection_id);")
            execute("CREATE INDEX IF NOT EXISTS idx_favorites_folder ON favorites(folder_id);")
            execute("CREATE INDEX IF NOT EXISTS idx_favorites_keyword ON favorites(keyword);")
            execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_favorites_keyword_scope ON favorites(keyword, connection_id) WHERE keyword IS NOT NULL;")
            execute("CREATE INDEX IF NOT EXISTS idx_folders_connection ON folders(connection_id);")
            execute("CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);")

            // Recreate FTS5 triggers referencing the new table
            execute("DROP TRIGGER IF EXISTS favorites_ai;")
            execute("DROP TRIGGER IF EXISTS favorites_ad;")
            execute("DROP TRIGGER IF EXISTS favorites_au;")
            execute("""
                CREATE TRIGGER IF NOT EXISTS favorites_ai AFTER INSERT ON favorites BEGIN
                    INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
                END;
            """)
            execute("""
                CREATE TRIGGER IF NOT EXISTS favorites_ad AFTER DELETE ON favorites BEGIN
                    INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
                END;
            """)
            execute("""
                CREATE TRIGGER IF NOT EXISTS favorites_au AFTER UPDATE ON favorites BEGIN
                    INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
                    INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
                END;
            """)

            // Rebuild FTS5 index to match new table rowids
            execute("INSERT INTO favorites_fts(favorites_fts) VALUES('rebuild');")

            setUserVersion(2)
        }
    }

    private func getUserVersion() -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return 0
        }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ version: Int32) {
        execute("PRAGMA user_version = \(version);")
    }

    // MARK: - Table Creation

    private func createTables() {
        let favoritesTable = """
            CREATE TABLE IF NOT EXISTS favorites (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                query TEXT NOT NULL,
                keyword TEXT,
                folder_id TEXT,
                connection_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """

        let foldersTable = """
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parent_id TEXT,
                connection_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """

        let ftsTable = """
            CREATE VIRTUAL TABLE IF NOT EXISTS favorites_fts USING fts5(
                name, query, keyword,
                content='favorites',
                content_rowid='rowid'
            );
            """

        let ftsInsertTrigger = """
            CREATE TRIGGER IF NOT EXISTS favorites_ai AFTER INSERT ON favorites BEGIN
                INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
            END;
            """

        let ftsDeleteTrigger = """
            CREATE TRIGGER IF NOT EXISTS favorites_ad AFTER DELETE ON favorites BEGIN
                INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
            END;
            """

        let ftsUpdateTrigger = """
            CREATE TRIGGER IF NOT EXISTS favorites_au AFTER UPDATE ON favorites BEGIN
                INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
                INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
            END;
            """

        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_favorites_connection ON favorites(connection_id);",
            "CREATE INDEX IF NOT EXISTS idx_favorites_folder ON favorites(folder_id);",
            "CREATE INDEX IF NOT EXISTS idx_favorites_keyword ON favorites(keyword);",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_favorites_keyword_scope ON favorites(keyword, connection_id) WHERE keyword IS NOT NULL;",
            "CREATE INDEX IF NOT EXISTS idx_folders_connection ON folders(connection_id);",
            "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);",
        ]

        execute(favoritesTable)
        execute(foldersTable)
        execute(ftsTable)
        execute(ftsInsertTrigger)
        execute(ftsDeleteTrigger)
        execute(ftsUpdateTrigger)
        indexes.forEach { execute($0) }
    }

    // MARK: - Helper Methods

    private func execute(_ sql: String) {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult == SQLITE_OK {
            let stepResult = sqlite3_step(statement)
            if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
                Self.logger.error("sqlite3_step failed (\(stepResult)): \(String(cString: sqlite3_errmsg(self.db)))")
            }
        } else {
            Self.logger.error("sqlite3_prepare_v2 failed (\(prepareResult)): \(String(cString: sqlite3_errmsg(self.db)))")
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Favorite Operations

    func addFavorite(_ favorite: SQLFavorite) async -> Bool {
        let idString = favorite.id.uuidString
        let nameString = favorite.name
        let queryString = favorite.query
        let keywordString = favorite.keyword
        let folderIdString = favorite.folderId?.uuidString
        let connectionIdString = favorite.connectionId?.uuidString
        let sortOrder = Int32(favorite.sortOrder)
        let createdAt = favorite.createdAt.timeIntervalSince1970
        let updatedAt = favorite.updatedAt.timeIntervalSince1970

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = """
                INSERT INTO favorites (id, name, query, keyword, folder_id, connection_id, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, nameString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, queryString, -1, SQLITE_TRANSIENT)

            if let keyword = keywordString {
                sqlite3_bind_text(statement, 4, keyword, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            if let folderId = folderIdString {
                sqlite3_bind_text(statement, 5, folderId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 5)
            }

            if let connectionId = connectionIdString {
                sqlite3_bind_text(statement, 6, connectionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 6)
            }

            sqlite3_bind_int(statement, 7, sortOrder)
            sqlite3_bind_double(statement, 8, createdAt)
            sqlite3_bind_double(statement, 9, updatedAt)

            let result = sqlite3_step(statement)
            if result != SQLITE_DONE {
                Self.logger.error("Failed to add favorite: \(String(cString: sqlite3_errmsg(self.db)))")
            }
            return result == SQLITE_DONE
        }
    }

    func updateFavorite(_ favorite: SQLFavorite) async -> Bool {
        let idString = favorite.id.uuidString
        let nameString = favorite.name
        let queryString = favorite.query
        let keywordString = favorite.keyword
        let folderIdString = favorite.folderId?.uuidString
        let connectionIdString = favorite.connectionId?.uuidString
        let sortOrder = Int32(favorite.sortOrder)
        let updatedAt = favorite.updatedAt.timeIntervalSince1970

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = """
                UPDATE favorites SET name = ?, query = ?, keyword = ?, folder_id = ?, connection_id = ?, sort_order = ?, updated_at = ?
                WHERE id = ?;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, 1, nameString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, queryString, -1, SQLITE_TRANSIENT)

            if let keyword = keywordString {
                sqlite3_bind_text(statement, 3, keyword, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 3)
            }

            if let folderId = folderIdString {
                sqlite3_bind_text(statement, 4, folderId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            if let connectionId = connectionIdString {
                sqlite3_bind_text(statement, 5, connectionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 5)
            }

            sqlite3_bind_int(statement, 6, sortOrder)
            sqlite3_bind_double(statement, 7, updatedAt)
            sqlite3_bind_text(statement, 8, idString, -1, SQLITE_TRANSIENT)

            let result = sqlite3_step(statement)
            return result == SQLITE_DONE
        }
    }

    func deleteFavorite(id: UUID) async -> Bool {
        let idString = id.uuidString
        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = "DELETE FROM favorites WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    func deleteFavorites(ids: [UUID]) async -> Bool {
        guard !ids.isEmpty else { return true }
        let idStrings = ids.map { $0.uuidString }
        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM favorites WHERE id IN (\(placeholders));"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, idString) in idStrings.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), idString, -1, SQLITE_TRANSIENT)
            }

            let result = sqlite3_step(statement)
            if result != SQLITE_DONE {
                Self.logger.error("Failed to batch delete favorites: \(String(cString: sqlite3_errmsg(self.db)))")
            }
            return result == SQLITE_DONE
        }
    }

    func fetchFavorite(id: UUID) async -> SQLFavorite? {
        let idString = id.uuidString
        return await performDatabaseWork { [weak self] in
            guard let self = self else { return nil }

            let sql = "SELECT id, name, query, keyword, folder_id, connection_id, sort_order, created_at, updated_at FROM favorites WHERE id = ? LIMIT 1;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                return self.parseFavorite(from: statement)
            }
            return nil
        }
    }

    func fetchFavorites(
        connectionId: UUID? = nil,
        folderId: UUID? = nil,
        searchText: String? = nil
    ) async -> [SQLFavorite] {
        let connectionIdString = connectionId?.uuidString
        let folderIdString = folderId?.uuidString

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return [] }

            var sql: String
            var bindIndex: Int32 = 1
            var hasConnectionFilter = false
            var hasFolderFilter = false

            if let searchText = searchText, !searchText.isEmpty {
                sql = """
                    SELECT f.id, f.name, f.query, f.keyword, f.folder_id, f.connection_id, f.sort_order, f.created_at, f.updated_at
                    FROM favorites f
                    INNER JOIN favorites_fts ON f.rowid = favorites_fts.rowid
                    WHERE favorites_fts MATCH ?
                    """

                if connectionIdString != nil {
                    sql += " AND (f.connection_id IS NULL OR f.connection_id = ?)"
                    hasConnectionFilter = true
                }

                if folderIdString != nil {
                    sql += " AND f.folder_id = ?"
                    hasFolderFilter = true
                }
            } else {
                sql = """
                    SELECT id, name, query, keyword, folder_id, connection_id, sort_order, created_at, updated_at
                    FROM favorites
                    """

                var whereClauses: [String] = []

                if connectionIdString != nil {
                    whereClauses.append("(connection_id IS NULL OR connection_id = ?)")
                    hasConnectionFilter = true
                }

                if folderIdString != nil {
                    whereClauses.append("folder_id = ?")
                    hasFolderFilter = true
                }

                if !whereClauses.isEmpty {
                    sql += " WHERE " + whereClauses.joined(separator: " AND ")
                }
            }

            sql += " ORDER BY sort_order ASC, name ASC;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            if let searchText = searchText, !searchText.isEmpty {
                let sanitized = "\"\(searchText.replacingOccurrences(of: "\"", with: "\"\""))\""
                sqlite3_bind_text(statement, bindIndex, sanitized, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }

            if let connId = connectionIdString, hasConnectionFilter {
                sqlite3_bind_text(statement, bindIndex, connId, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }

            if let foldId = folderIdString, hasFolderFilter {
                sqlite3_bind_text(statement, bindIndex, foldId, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }

            var favorites: [SQLFavorite] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let favorite = self.parseFavorite(from: statement) {
                    favorites.append(favorite)
                }
            }

            return favorites
        }
    }

    // MARK: - Folder Operations

    func addFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let idString = folder.id.uuidString
        let nameString = folder.name
        let parentIdString = folder.parentId?.uuidString
        let connectionIdString = folder.connectionId?.uuidString
        let sortOrder = Int32(folder.sortOrder)
        let createdAt = folder.createdAt.timeIntervalSince1970
        let updatedAt = folder.updatedAt.timeIntervalSince1970

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = """
                INSERT INTO folders (id, name, parent_id, connection_id, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, nameString, -1, SQLITE_TRANSIENT)

            if let parentId = parentIdString {
                sqlite3_bind_text(statement, 3, parentId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 3)
            }

            if let connectionId = connectionIdString {
                sqlite3_bind_text(statement, 4, connectionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            sqlite3_bind_int(statement, 5, sortOrder)
            sqlite3_bind_double(statement, 6, createdAt)
            sqlite3_bind_double(statement, 7, updatedAt)

            let result = sqlite3_step(statement)
            return result == SQLITE_DONE
        }
    }

    func updateFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let idString = folder.id.uuidString
        let nameString = folder.name
        let parentIdString = folder.parentId?.uuidString
        let connectionIdString = folder.connectionId?.uuidString
        let sortOrder = Int32(folder.sortOrder)
        let updatedAt = folder.updatedAt.timeIntervalSince1970

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            let sql = """
                UPDATE folders SET name = ?, parent_id = ?, connection_id = ?, sort_order = ?, updated_at = ?
                WHERE id = ?;
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, 1, nameString, -1, SQLITE_TRANSIENT)

            if let parentId = parentIdString {
                sqlite3_bind_text(statement, 2, parentId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 2)
            }

            if let connectionId = connectionIdString {
                sqlite3_bind_text(statement, 3, connectionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 3)
            }

            sqlite3_bind_int(statement, 4, sortOrder)
            sqlite3_bind_double(statement, 5, updatedAt)
            sqlite3_bind_text(statement, 6, idString, -1, SQLITE_TRANSIENT)

            let result = sqlite3_step(statement)
            return result == SQLITE_DONE
        }
    }

    func deleteFolder(id: UUID) async -> Bool {
        let idString = id.uuidString
        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            guard sqlite3_exec(self.db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                return false
            }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            // Find the parent_id of the folder being deleted
            let findParentSQL = "SELECT parent_id FROM folders WHERE id = ?;"
            var findStatement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, findParentSQL, -1, &findStatement, nil) == SQLITE_OK else {
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                return false
            }

            sqlite3_bind_text(findStatement, 1, idString, -1, SQLITE_TRANSIENT)

            var parentId: String?
            if sqlite3_step(findStatement) == SQLITE_ROW {
                parentId = sqlite3_column_text(findStatement, 0).map { String(cString: $0) }
            }
            sqlite3_finalize(findStatement)

            // Move child favorites to the parent folder
            let moveFavoritesSQL = "UPDATE favorites SET folder_id = ? WHERE folder_id = ?;"
            var moveFavStatement: OpaquePointer?
            if sqlite3_prepare_v2(self.db, moveFavoritesSQL, -1, &moveFavStatement, nil) == SQLITE_OK {
                if let parentId = parentId {
                    sqlite3_bind_text(moveFavStatement, 1, parentId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(moveFavStatement, 1)
                }
                sqlite3_bind_text(moveFavStatement, 2, idString, -1, SQLITE_TRANSIENT)
                let moveFavResult = sqlite3_step(moveFavStatement)
                sqlite3_finalize(moveFavStatement)
                if moveFavResult != SQLITE_DONE {
                    sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                    return false
                }
            } else {
                sqlite3_finalize(moveFavStatement)
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                return false
            }

            // Move child subfolders to the parent folder
            let moveSubfoldersSQL = "UPDATE folders SET parent_id = ? WHERE parent_id = ?;"
            var moveSubStatement: OpaquePointer?
            if sqlite3_prepare_v2(self.db, moveSubfoldersSQL, -1, &moveSubStatement, nil) == SQLITE_OK {
                if let parentId = parentId {
                    sqlite3_bind_text(moveSubStatement, 1, parentId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(moveSubStatement, 1)
                }
                sqlite3_bind_text(moveSubStatement, 2, idString, -1, SQLITE_TRANSIENT)
                let moveSubResult = sqlite3_step(moveSubStatement)
                sqlite3_finalize(moveSubStatement)
                if moveSubResult != SQLITE_DONE {
                    sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                    return false
                }
            } else {
                sqlite3_finalize(moveSubStatement)
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                return false
            }

            // Delete the folder
            let deleteSQL = "DELETE FROM folders WHERE id = ?;"
            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
                return false
            }

            sqlite3_bind_text(deleteStatement, 1, idString, -1, SQLITE_TRANSIENT)
            let result = sqlite3_step(deleteStatement)
            sqlite3_finalize(deleteStatement)

            if result == SQLITE_DONE {
                sqlite3_exec(self.db, "COMMIT;", nil, nil, nil)
            } else {
                sqlite3_exec(self.db, "ROLLBACK;", nil, nil, nil)
            }

            return result == SQLITE_DONE
        }
    }

    func fetchFolders(connectionId: UUID? = nil) async -> [SQLFavoriteFolder] {
        let connectionIdString = connectionId?.uuidString

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return [] }

            var sql = """
                SELECT id, name, parent_id, connection_id, sort_order, created_at, updated_at
                FROM folders
                """

            if connectionIdString != nil {
                sql += " WHERE (connection_id IS NULL OR connection_id = ?)"
            }

            sql += " ORDER BY sort_order ASC, name ASC;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return []
            }

            defer { sqlite3_finalize(statement) }

            if let connId = connectionIdString {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, connId, -1, SQLITE_TRANSIENT)
            }

            var folders: [SQLFavoriteFolder] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let folder = self.parseFolder(from: statement) {
                    folders.append(folder)
                }
            }

            return folders
        }
    }

    // MARK: - Keyword Support

    func fetchKeywordMap(connectionId: UUID? = nil) async -> [String: (name: String, query: String)] {
        let connectionIdString = connectionId?.uuidString

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return [:] }

            var sql = """
                SELECT keyword, name, query FROM favorites
                WHERE keyword IS NOT NULL
                """

            if connectionIdString != nil {
                sql += " AND (connection_id IS NULL OR connection_id = ?)"
            }

            sql += ";"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return [:]
            }

            defer { sqlite3_finalize(statement) }

            if let connId = connectionIdString {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, connId, -1, SQLITE_TRANSIENT)
            }

            var map: [String: (name: String, query: String)] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let keyword = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                      let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                      let query = sqlite3_column_text(statement, 2).map({ String(cString: $0) })
                else {
                    continue
                }
                map[keyword] = (name: name, query: query)
            }

            return map
        }
    }

    func isKeywordAvailable(
        _ keyword: String,
        connectionId: UUID?,
        excludingFavoriteId: UUID? = nil
    ) async -> Bool {
        let connectionIdString = connectionId?.uuidString
        let excludeIdString = excludingFavoriteId?.uuidString

        return await performDatabaseWork { [weak self] in
            guard let self = self else { return false }

            var sql: String
            var bindIndex: Int32 = 1

            if connectionIdString != nil {
                sql = """
                    SELECT COUNT(*) FROM favorites
                    WHERE keyword = ?
                    AND (connection_id IS NULL OR connection_id = ?)
                    """
            } else {
                sql = """
                    SELECT COUNT(*) FROM favorites
                    WHERE keyword = ?
                    AND connection_id IS NULL
                    """
            }

            if excludeIdString != nil {
                sql += " AND id != ?"
            }

            sql += ";"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            defer { sqlite3_finalize(statement) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            sqlite3_bind_text(statement, bindIndex, keyword, -1, SQLITE_TRANSIENT)
            bindIndex += 1

            if let connId = connectionIdString {
                sqlite3_bind_text(statement, bindIndex, connId, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }

            if let excludeId = excludeIdString {
                sqlite3_bind_text(statement, bindIndex, excludeId, -1, SQLITE_TRANSIENT)
            }

            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_int(statement, 0) == 0
            }
            return false
        }
    }

    // MARK: - Parsing Helpers

    private func parseFavorite(from statement: OpaquePointer?) -> SQLFavorite? {
        guard let statement = statement else { return nil }

        guard let idString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idString),
              let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let query = sqlite3_column_text(statement, 2).map({ String(cString: $0) })
        else {
            return nil
        }

        let keyword = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let folderId = sqlite3_column_text(statement, 4).flatMap { UUID(uuidString: String(cString: $0)) }
        let connectionId = sqlite3_column_text(statement, 5).flatMap { UUID(uuidString: String(cString: $0)) }
        let sortOrder = Int(sqlite3_column_int(statement, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))

        return SQLFavorite(
            id: id,
            name: name,
            query: query,
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func parseFolder(from statement: OpaquePointer?) -> SQLFavoriteFolder? {
        guard let statement = statement else { return nil }

        guard let idString = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idString),
              let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) })
        else {
            return nil
        }

        let parentId = sqlite3_column_text(statement, 2).flatMap { UUID(uuidString: String(cString: $0)) }
        let connectionId = sqlite3_column_text(statement, 3).flatMap { UUID(uuidString: String(cString: $0)) }
        let sortOrder = Int(sqlite3_column_int(statement, 4))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

        return SQLFavoriteFolder(
            id: id,
            name: name,
            parentId: parentId,
            connectionId: connectionId,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
