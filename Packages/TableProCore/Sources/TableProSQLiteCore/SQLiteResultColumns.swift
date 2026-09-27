import CSQLite

/// The columns a statement returns, read once its first step has run.
///
/// `sqlite3_prepare_v2` compiles against the schema this connection last read and does not look at
/// the file. The first `sqlite3_step` compares the schema cookie and, when another connection has
/// changed the table since, prepares the statement again with the new columns. Read before that
/// step, a `SELECT *` on the session connection right after an `ALTER TABLE` run on a pooled one
/// named the old columns and dropped the new column's values from every row. The structure editor
/// alters on a pooled connection, so that was the first reload after every structure save.
///
/// Both plugins that link their own SQLite share this, so it compiles against that library's header
/// and never against the SDK's `SQLite3` module, whose `link "sqlite3"` would ask the linker for
/// macOS's build too.
public enum SQLiteResultColumns {
    public struct FirstStep: Sendable {
        public let result: Int32
        public let names: [String]
        public let typeNames: [String]

        public var count: Int32 { Int32(names.count) }
    }

    public static func stepFirst(_ statement: OpaquePointer?) -> FirstStep {
        let result = sqlite3_step(statement)
        let count = sqlite3_column_count(statement)
        var names: [String] = []
        var typeNames: [String] = []
        for index in 0..<count {
            names.append(sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column_\(index)")
            typeNames.append(sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? "")
        }
        return FirstStep(result: result, names: names, typeNames: typeNames)
    }
}
