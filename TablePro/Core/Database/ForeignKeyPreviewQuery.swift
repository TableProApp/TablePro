//
//  ForeignKeyPreviewQuery.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The single-row lookup behind Preview Referenced Row.
///
/// Pulled out of the popover so the clause it ends in can be tested. It shipped as a bare
/// `OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY`, which T-SQL rejects outright, and the popover reported
/// the failure as "Failed to load referenced row": the same thing it says for a key with no
/// matching row, so the preview looked empty rather than broken on every SQL Server connection.
enum ForeignKeyPreviewQuery {
    static func singleRow(
        quotedTable: String,
        quotedColumn: String,
        escapedValue: String,
        dialect: SQLDialectDescriptor?
    ) -> String {
        "SELECT * FROM \(quotedTable) WHERE \(quotedColumn) = '\(escapedValue)' \(limitClause(dialect: dialect))"
    }

    /// OFFSET/FETCH is part of ORDER BY in T-SQL and Oracle, so the dialect's filler clause travels
    /// with it. A dialect that supplies an empty one is saying it does not need the filler.
    static func limitClause(dialect: SQLDialectDescriptor?) -> String {
        switch dialect?.paginationStyle ?? .limit {
        case .offsetFetch:
            let orderBy = dialect?.offsetFetchOrderBy ?? ""
            let orderByPrefix = orderBy.isEmpty ? "" : "\(orderBy) "
            return "\(orderByPrefix)OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"
        case .limit:
            return "LIMIT 1"
        }
    }
}
