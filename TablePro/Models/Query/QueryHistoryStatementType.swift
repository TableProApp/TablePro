import Foundation

enum QueryHistoryStatementType: String, Codable, CaseIterable, Sendable {
    case select
    case insert
    case update
    case delete
    case ddl
    case other

    static func classify(_ query: String) -> QueryHistoryStatementType {
        switch QueryClassifier.leadingKeyword(of: query) {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH", "TABLE", "VALUES", "PRAGMA":
            return .select
        case "INSERT", "REPLACE", "UPSERT", "MERGE", "COPY", "LOAD":
            return .insert
        case "UPDATE":
            return .update
        case "DELETE", "TRUNCATE":
            return .delete
        case "CREATE", "ALTER", "DROP", "RENAME", "COMMENT", "GRANT", "REVOKE", "SET", "ANALYZE", "VACUUM", "REINDEX":
            return .ddl
        default:
            return .other
        }
    }

    var displayName: String {
        switch self {
        case .select: return String(localized: "Read")
        case .insert: return String(localized: "Insert")
        case .update: return String(localized: "Update")
        case .delete: return String(localized: "Delete")
        case .ddl: return String(localized: "Structure")
        case .other: return String(localized: "Other")
        }
    }
}
