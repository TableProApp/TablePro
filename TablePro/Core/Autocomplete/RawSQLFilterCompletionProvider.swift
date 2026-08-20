//
//  RawSQLFilterCompletionProvider.swift
//  TablePro
//

import Foundation

struct RawSQLFilterCompletionItem: Equatable {
    let label: String
    let insertText: String
}

struct RawSQLFilterCompletions {
    let items: [RawSQLFilterCompletionItem]
    let replacementRange: NSRange
}

@MainActor
final class RawSQLFilterCompletionProvider {
    private let engine: CompletionEngine
    private let tableName: String

    init(schemaProvider: SQLSchemaProvider, databaseType: DatabaseType, tableName: String) {
        let dialect = PluginManager.shared.sqlDialect(for: databaseType)
        let statementCompletions = PluginManager.shared.statementCompletions(for: databaseType)
        self.engine = CompletionEngine(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions
        )
        self.tableName = tableName
    }

    func completions(fieldText: String, cursor: Int) async -> RawSQLFilterCompletions? {
        guard let context = await engine.filterCompletions(
            fragment: fieldText,
            cursorPosition: cursor,
            tableName: tableName
        ) else {
            return nil
        }

        let items = context.items.map {
            RawSQLFilterCompletionItem(label: $0.label, insertText: $0.insertText)
        }
        guard !items.isEmpty else { return nil }

        return RawSQLFilterCompletions(items: items, replacementRange: context.replacementRange)
    }
}
