#if os(iOS)
import SQLite3
#else
import CSQLite
#endif

// Column names read after the first step: prepare compiles against the schema this connection last read, and the
// first step re-prepares when another connection altered the table, as the structure editor's pooled one does.
// macOS compiles this against the vendored SQLite's header, since the SDK module's `link "sqlite3"` would pull in
// macOS's build too; iOS has no vendored build and uses the SDK's.
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
