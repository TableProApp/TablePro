import Foundation
import TableProPluginKit
import TableProSQLGrammar

struct QueryFormatResult {
    let text: String
    let cursorOffset: Int?
}

protocol QueryFormatting {
    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult
}

struct SQLQueryFormatter: QueryFormatting {
    private let dialect: DatabaseType
    private let grammar: SQLLexicalGrammar?
    private let options: SQLFormatterOptions
    private let formatter = SQLFormatterService()

    init(dialect: DatabaseType, grammar: SQLLexicalGrammar? = nil, options: SQLFormatterOptions = .default) {
        self.dialect = dialect
        self.grammar = grammar
        self.options = options
    }

    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult {
        let result = try formatter.format(
            text,
            dialect: dialect,
            grammar: grammar,
            cursorOffset: cursorOffset,
            options: options
        )
        return QueryFormatResult(text: result.formattedSQL, cursorOffset: result.cursorOffset)
    }
}

@MainActor
enum QueryFormatterFactory {
    static func make(for databaseType: DatabaseType?) -> QueryFormatting? {
        make(for: databaseType) { AppSettingsManager.shared.formatterOptions }
    }

    // Throws when the linked folder's rules file can't be read, rather than format with Settings. `grammar` is the one
    // the tab's statements are split with, so a literal or a comment ends where the connected engine ends it.
    static func make(
        for databaseType: DatabaseType?,
        sourceFileURL: URL?,
        grammar: SQLLexicalGrammar? = nil
    ) throws -> QueryFormatting? {
        try make(for: databaseType, grammar: grammar) { try SQLFormatterRuleSource.options(forFileAt: sourceFileURL) }
    }

    // Nil for a language with no formatter of its own. The SQL formatter reads a Redis key `user:1` as
    // `user :1`, an etcd path as `/ config / name` and a SurrealQL record id `person:tobie` as two tokens,
    // so running it there changes what the command does.
    private static func make(
        for databaseType: DatabaseType?,
        grammar: SQLLexicalGrammar? = nil,
        sqlOptions: () throws -> SQLFormatterOptions
    ) rethrows -> QueryFormatting? {
        let dialect = databaseType ?? .mysql

        // Elasticsearch, Typesense and Weaviate highlight as JavaScript for their JSON bodies, and the
        // shell formatter joins a body onto its request line. Only a MongoDB script is JavaScript.
        if QueryStatementModel.forDatabaseType(dialect) == .javascript {
            return MongoShellFormatter()
        }

        switch PluginManager.shared.editorLanguage(for: dialect) {
        case .sql:
            return SQLQueryFormatter(dialect: dialect, grammar: grammar, options: try sqlOptions())
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
