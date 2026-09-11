//
//  LeadingRowsStatement.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A read sent to an engine that returns only its leading rows, with the LIMIT stated.
///
/// Such an engine answers a statement that names no limit with a smaller default of its own
/// (Cloudflare R2 SQL stops at 500), so leaving the limit out does not mean "all rows" there. Every
/// read the user did not limit is therefore sent with one: one row past the app's row cap, so a
/// trimmed result is still detected and offers Fetch All, or the engine's ceiling when nothing caps it.
struct LeadingRowsStatement: Equatable {
    let sql: String
    let rowCap: Int?

    static func bound(
        _ sql: String,
        rowCap: Int?,
        maximumRows: Int,
        autoLimitStyle: AutoLimitStyle,
        lexicalDialect: SqlDialect
    ) -> LeadingRowsStatement {
        let unchanged = LeadingRowsStatement(sql: sql, rowCap: rowCap)
        guard !SQLLimitDetector.hasExplicitRowLimit(sql, autoLimitStyle: autoLimitStyle, lexicalDialect: lexicalDialect)
        else { return unchanged }

        let cap = rowCap.map { min($0, maximumRows) }
        let fetched = cap.map { min($0 + 1, maximumRows) } ?? maximumRows
        guard let limited = appending(limit: fetched, to: sql, style: autoLimitStyle) else { return unchanged }
        return LeadingRowsStatement(sql: limited, rowCap: cap)
    }

    /// The clause goes on a line of its own, so a trailing `--` comment cannot swallow it.
    private static func appending(limit: Int, to sql: String, style: AutoLimitStyle) -> String? {
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") {
            statement = String(statement.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch style {
        case .limit:
            return "\(statement)\nLIMIT \(limit)"
        case .fetchFirst:
            return "\(statement)\nFETCH FIRST \(limit) ROWS ONLY"
        case .top, .none:
            return nil
        @unknown default:
            return nil
        }
    }
}

@MainActor
extension LeadingRowsStatement {
    /// The statement to send for a query tab's read, or for re-running one to export it.
    static func resolve(_ sql: String, rowCap: Int?, databaseType: DatabaseType) -> LeadingRowsStatement {
        guard let maximumRows = PluginManager.shared.paginationCapability(for: databaseType).maximumRows,
              QueryExecutor.qualifiesForRowCap(sql: sql, tabType: .query, databaseType: databaseType)
        else { return LeadingRowsStatement(sql: sql, rowCap: rowCap) }
        return bound(
            sql,
            rowCap: rowCap,
            maximumRows: maximumRows,
            autoLimitStyle: PluginManager.shared.autoLimitStyle(for: databaseType),
            lexicalDialect: SqlDialect.from(databaseTypeId: databaseType.rawValue)
        )
    }
}
