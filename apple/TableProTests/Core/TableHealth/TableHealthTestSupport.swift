import Foundation
@testable import TablePro
import TableProPluginKit

enum TableHealthFixture {
    static func result(columns: [String], rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows.map { row in row.map { $0.map { PluginCellValue.text($0) } ?? .null } },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    static func empty() -> QueryResult {
        result(columns: [], rows: [])
    }

    static func postgresContext(database: String = "shop") -> TableHealthQueryContext {
        TableHealthQueryContext(
            database: database,
            quote: { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" },
            literal: { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        )
    }

    static func mysqlContext(database: String = "shop") -> TableHealthQueryContext {
        TableHealthQueryContext(
            database: database,
            quote: { "`" + $0.replacingOccurrences(of: "`", with: "``") + "`" },
            literal: {
                "'" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
            }
        )
    }

    static func finding(
        _ kind: TableHealthCheckKind = .missingPrimaryKey,
        schema: String? = "public",
        table: String?,
        object: String? = nil,
        fixSQL: String? = "SELECT 1;"
    ) -> TableHealthFinding {
        TableHealthFinding(
            kind: kind, schema: schema, table: table, objectName: object, detail: "", fixSQL: fixSQL
        )
    }

    static func report(
        _ checks: [(kind: TableHealthCheckKind, outcome: TableHealthCheckResult.Outcome, findings: [TableHealthFinding])],
        generatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> TableHealthReport {
        TableHealthReport(
            database: "shop",
            checks: checks.map {
                TableHealthCheckResult(check: TableHealthCheck(kind: $0.kind, summary: ""), findings: $0.findings, outcome: $0.outcome)
            },
            generatedAt: generatedAt
        )
    }
}
