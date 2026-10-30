import Foundation
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLVocabulary

extension SQLCompletionProvider {
    convenience init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType? = nil,
        dialect: SQLDialectDescriptor? = nil,
        statementCompletions: [CompletionEntry] = [],
        grammar: SQLLexicalGrammar? = nil
    ) {
        self.init(
            catalog: schemaProvider,
            grammar: grammar ?? databaseType?.lexicalGrammar ?? .ansi,
            vocabulary: SQLCompletionVocabulary(
                dialect: dialect, statementCompletions: statementCompletions, databaseType: databaseType
            )
        )
    }
}

extension SQLCompletionVocabulary {
    init(dialect: SQLDialectDescriptor?, statementCompletions: [CompletionEntry], databaseType: DatabaseType? = nil) {
        self.init(
            functions: dialect?.functions ?? [],
            bareFunctions: databaseType.flatMap { SQLEngineVocabulary.curated(forDatabaseTypeId: $0.rawValue) }?
                .bareFunctions ?? [],
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
