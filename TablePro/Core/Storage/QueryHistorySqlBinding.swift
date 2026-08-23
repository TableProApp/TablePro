import Foundation
import SQLite3

enum QueryHistorySqlBinding: Sendable {
    case text(String)
    case double(Double)
    case int(Int32)
    case int64(Int64)

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(to statement: OpaquePointer?, at index: Int32) {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .int(let value):
            sqlite3_bind_int(statement, index, value)
        case .int64(let value):
            sqlite3_bind_int64(statement, index, value)
        }
    }
}

struct QueryHistorySqlClause {
    private(set) var sql: String = ""
    private(set) var bindings: [QueryHistorySqlBinding] = []

    mutating func append(_ fragment: String, _ newBindings: QueryHistorySqlBinding...) {
        sql += fragment
        bindings.append(contentsOf: newBindings)
    }

    mutating func append(_ fragment: String, bindings newBindings: [QueryHistorySqlBinding]) {
        sql += fragment
        bindings.append(contentsOf: newBindings)
    }

    static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
