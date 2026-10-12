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
    private let keywordCase: SQLKeywordCase
    private let formatter = SQLFormatterService()

    init(dialect: DatabaseType, keywordCase: SQLKeywordCase = .default) {
        self.dialect = dialect
        self.keywordCase = keywordCase
    }

    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult {
        var options = SQLFormatterOptions.default
        options.keywordCase = keywordCase.prefersUppercase ? .upper : .lower
        let result = try formatter.format(text, dialect: dialect, cursorOffset: cursorOffset, options: options)
        return QueryFormatResult(text: result.formattedSQL, cursorOffset: result.cursorOffset)
    }
}

@MainActor
enum QueryFormatterFactory {
    /// Nil for a language with no formatter of its own. The SQL formatter reads a Redis key `user:1` as
    /// `user :1`, an etcd path as `/ config / name` and a SurrealQL record id `person:tobie` as two tokens,
    /// so running it there changes what the command does.
    static func make(for databaseType: DatabaseType?) -> QueryFormatting? {
        let dialect = databaseType ?? .mysql

        // Elasticsearch, Typesense and Weaviate highlight as JavaScript for their JSON bodies, and the
        // shell formatter joins a body onto its request line. Only a MongoDB script is JavaScript.
        if QueryStatementModel.forDatabaseType(dialect) == .javascript {
            return MongoShellFormatter()
        }

        switch PluginManager.shared.editorLanguage(for: dialect) {
        case .sql:
            return SQLQueryFormatter(dialect: dialect, keywordCase: AppSettingsManager.shared.editor.keywordCase)
        case .javascript:
            return ConsoleRequestFormatter()
        case .bash, .custom:
            return nil
        }
    }

    static func supportsFormatting(_ databaseType: DatabaseType?) -> Bool {
        make(for: databaseType) != nil
    }
}
