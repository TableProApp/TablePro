import CSQLite

// SQLite keeps a NUL inside text, so text crosses the C API with its byte count, never as a C string.
public enum SQLiteText {
    public static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        // SQLite does not check that text is UTF-8: a bad byte is repaired rather than losing the whole value.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    public static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        sqlite3_bind_text64(
            statement, index, value, sqlite3_uint64(value.utf8.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8)
        )
    }
}
