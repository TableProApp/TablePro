//
//  IndexKeyDialect.swift
//  TablePro
//

import Foundation

struct IndexKeyDialect: Equatable, Sendable {
    let takesPrefixLengths: Bool
    let takesExpressions: Bool

    static let columnsOnly = IndexKeyDialect(takesPrefixLengths: false, takesExpressions: false)

    static func forType(_ databaseType: DatabaseType) -> IndexKeyDialect {
        switch databaseType {
        case .mysql:
            return IndexKeyDialect(takesPrefixLengths: true, takesExpressions: true)
        case .mariadb, .tidb, .oceanbase:
            return IndexKeyDialect(takesPrefixLengths: true, takesExpressions: false)
        case .postgresql, .pglite, .sqlite, .libsql, .turso, .cloudflareD1, .duckdb:
            return IndexKeyDialect(takesPrefixLengths: false, takesExpressions: true)
        default:
            return .columnsOnly
        }
    }
}
