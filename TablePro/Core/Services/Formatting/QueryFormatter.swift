import Foundation
import TableProPluginKit

struct QueryFormatResult {
    let text: String
    let cursorOffset: Int?
}

protocol QueryFormatting {
    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult
}

struct SQLQueryFormatter: QueryFormatting {
    private let dialect: DatabaseType
    private let formatter = SQLFormatterService()

    init(dialect: DatabaseType) {
        self.dialect = dialect
    }

    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult {
        let result = try formatter.format(text, dialect: dialect, cursorOffset: cursorOffset, options: .default)
        return QueryFormatResult(text: result.formattedSQL, cursorOffset: result.cursorOffset)
    }
}

@MainActor
enum QueryFormatterFactory {
    static func make(for databaseType: DatabaseType?) -> QueryFormatting {
        let dialect = databaseType ?? .mysql

        switch PluginManager.shared.editorLanguage(for: dialect) {
        case .javascript:
            return MongoShellFormatter()
        default:
            return SQLQueryFormatter(dialect: dialect)
        }
    }
}
