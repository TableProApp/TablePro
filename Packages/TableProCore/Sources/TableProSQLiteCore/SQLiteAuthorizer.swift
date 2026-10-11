import CSQLite

/// Denies the SQLite functions that turn plain SQL into a native-code primitive on the machine
/// running the query. `fts3_tokenizer` registers an arbitrary pointer as a tokenizer from a bound
/// blob and dereferences it (measured: a SIGSEGV on macOS's libsqlite3 and on every server build
/// tried), and `load_extension` loads a shared library. Both are denied on every SQLite connection
/// either plugin opens, local or remote, so a crafted statement from the editor, an import, or an AI
/// or MCP client cannot reach them. Extensions the user lists load through the C API instead, which
/// the authorizer does not see.
public enum SQLiteAuthorizer {
    private static let function: Int32 = SQLITE_FUNCTION
    private static let denied: Set<String> = ["fts3_tokenizer", "load_extension"]

    private static let callback: @convention(c) (
        UnsafeMutableRawPointer?, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32 = { _, action, _, arg2, _, _ in
        guard action == function, let arg2 else { return SQLITE_OK }
        let name = String(cString: arg2).lowercased()
        return denied.contains(name) ? SQLITE_DENY : SQLITE_OK
    }

    public static func install(on db: OpaquePointer?) {
        sqlite3_set_authorizer(db, callback, nil)
    }
}
