import Foundation

extension SQLFavoriteStorage {
    // Run in one transaction by migrateIfNeeded; the version stamp is the last step.
    static let version2MigrationStatements: [String] = [
        "ALTER TABLE favorites RENAME TO favorites_old",
        """
        CREATE TABLE IF NOT EXISTS favorites (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL,
            keyword TEXT, folder_id TEXT, connection_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
        )
        """,
        """
        INSERT INTO favorites SELECT id, name, query, keyword, folder_id, connection_id,
        sort_order, created_at, updated_at FROM favorites_old
        """,
        "DROP TABLE favorites_old",
        "ALTER TABLE folders RENAME TO folders_old",
        """
        CREATE TABLE IF NOT EXISTS folders (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
        )
        """,
        """
        INSERT INTO folders SELECT id, name, parent_id, connection_id,
        sort_order, created_at, updated_at FROM folders_old
        """,
        "DROP TABLE folders_old",
        "CREATE INDEX IF NOT EXISTS idx_favorites_connection ON favorites(connection_id);",
        "CREATE INDEX IF NOT EXISTS idx_favorites_folder ON favorites(folder_id);",
        "CREATE INDEX IF NOT EXISTS idx_favorites_keyword ON favorites(keyword);",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_favorites_keyword_scope ON favorites(keyword, connection_id) WHERE keyword IS NOT NULL;",
        "CREATE INDEX IF NOT EXISTS idx_folders_connection ON folders(connection_id);",
        "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);",
        "DROP TRIGGER IF EXISTS favorites_ai;",
        "DROP TRIGGER IF EXISTS favorites_ad;",
        "DROP TRIGGER IF EXISTS favorites_au;",
        """
        CREATE TRIGGER IF NOT EXISTS favorites_ai AFTER INSERT ON favorites BEGIN
            INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS favorites_ad AFTER DELETE ON favorites BEGIN
            INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS favorites_au AFTER UPDATE ON favorites BEGIN
            INSERT INTO favorites_fts(favorites_fts, rowid, name, query, keyword) VALUES('delete', old.rowid, old.name, old.query, old.keyword);
            INSERT INTO favorites_fts(rowid, name, query, keyword) VALUES (new.rowid, new.name, new.query, new.keyword);
        END;
        """,
        "INSERT INTO favorites_fts(favorites_fts) VALUES('rebuild');",
        "PRAGMA user_version = 2;",
    ]
}
