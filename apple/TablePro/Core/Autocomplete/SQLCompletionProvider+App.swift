import Foundation
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar

extension SQLCompletionProvider {
    convenience init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType? = nil,
        dialect: SQLDialectDescriptor? = nil,
        statementCompletions: [CompletionEntry] = []
    ) {
        self.init(
            catalog: schemaProvider,
            grammar: databaseType?.lexicalGrammar ?? .ansi,
            vocabulary: SQLCompletionVocabulary(dialect: dialect, statementCompletions: statementCompletions)
        )
    }

    func setDatabaseType(
        _ type: DatabaseType,
        dialect: SQLDialectDescriptor? = nil,
        statementCompletions: [CompletionEntry] = []
    ) {
        update(
            grammar: type.lexicalGrammar,
            vocabulary: SQLCompletionVocabulary(dialect: dialect, statementCompletions: statementCompletions)
        )
    }
}

extension SQLCompletionVocabulary {
    init(dialect: SQLDialectDescriptor?, statementCompletions: [CompletionEntry]) {
        self.init(
            functions: dialect?.functions ?? [],
            functionNamesAreCaseInsensitive: dialect?.functionNamesAreCaseInsensitive ?? false,
            operators: dialect?.operators.map {
                Operator(symbol: $0.symbol, summary: $0.summary, appliesToTypes: $0.appliesToTypes)
            } ?? [],
            dataTypes: dialect?.dataTypes ?? [],
            tableOptions: dialect?.tableOptions,
            statementCompletions: statementCompletions.map {
                StatementCompletion(label: $0.label, insertText: $0.insertText)
            }
        )
    }
}
