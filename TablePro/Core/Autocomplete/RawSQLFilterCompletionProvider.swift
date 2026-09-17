//
//  RawSQLFilterCompletionProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct RawSQLFilterCompletionItem: Equatable {
    let label: String
    let insertText: String
    /// Where the caret lands relative to the insertion start, in UTF-16 units. Resolved by
    /// `SQLCompletionInsertion` so this field behaves exactly as the editor's popup does; the
    /// filter field used to splice the raw text and park the caret past the closing parenthesis.
    let cursorOffset: Int
}

struct RawSQLFilterCompletions {
    let items: [RawSQLFilterCompletionItem]
    let replacementRange: NSRange
}

@MainActor
final class RawSQLFilterCompletionProvider {
    private let engine: CompletionEngine
    private let tableName: String

    init(
        schemaProvider: SQLSchemaProvider,
        databaseType: DatabaseType,
        tableName: String,
        profile: QueryCompletionProfile? = nil
    ) {
        let dialect = profile?.resolvedDialect ?? PluginManager.shared.sqlDialect(for: databaseType)
        let statementCompletions = profile?.statementCompletions
            ?? PluginManager.shared.statementCompletions(for: databaseType)
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
            tableName: tableName,
            keywordCase: AppSettingsManager.shared.editor.keywordCase
        ) else {
            return nil
        }
        guard !SQLCompletionTriggerPolicy.suppressesEmptyPrefix(
            context.sqlContext,
            isManualTrigger: false
        ) else { return nil }

        let items = context.items.map { item in
            let resolution = SQLCompletionInsertion.resolve(for: item)
            return RawSQLFilterCompletionItem(
                label: item.label,
                insertText: resolution.text,
                cursorOffset: resolution.cursorOffset
            )
        }
        guard !items.isEmpty else { return nil }

        return RawSQLFilterCompletions(items: items, replacementRange: context.replacementRange)
    }
}
