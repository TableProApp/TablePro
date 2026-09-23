import CSQLite

/// The two SQLite calls extension loading needs, against one open handle.
public struct SQLiteExtensionLoading {
    private let db: OpaquePointer

    public init(db: OpaquePointer) {
        self.db = db
    }

    /// Sets `SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION` and answers whether loading is on afterwards.
    /// A call SQLite rejects answers the state that fails safe: not on after an attempt to turn it
    /// on, still on after an attempt to turn it off.
    public func setEnabled(_ enabled: Bool) -> Bool {
        var state: Int32 = -1
        guard tablepro_sqlite3_set_extension_loading(db, enabled ? 1 : 0, &state) == SQLITE_OK else {
            return !enabled
        }
        return state == 1
    }

    /// Nil on success, otherwise SQLite's error text.
    public func load(file: String, entryPoint: String?) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(error) }
        guard sqlite3_load_extension(db, file, entryPoint, &error) != SQLITE_OK else { return nil }
        return error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
    }
}
