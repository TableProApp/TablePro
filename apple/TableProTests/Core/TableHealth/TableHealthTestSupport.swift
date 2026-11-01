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
        TableHealthQueryContext(database: database) { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    }

    static func mysqlContext(database: String = "shop") -> TableHealthQueryContext {
        TableHealthQueryContext(database: database) { "`" + $0.replacingOccurrences(of: "`", with: "``") + "`" }
    }
}
