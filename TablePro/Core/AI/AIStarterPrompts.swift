//
//  AIStarterPrompts.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Static suggestion strings shown as chips in the AI chat empty state.
/// Bucketed by the connection's `EditorLanguage` so SQL, document, and
/// key-value users see prompts that fit their domain.
enum AIStarterPrompts {
    static func suggestions(for databaseType: DatabaseType) -> [String] {
        switch PluginManager.shared.editorLanguage(for: databaseType) {
        case .javascript:
            return [
                String(localized: "List collections and document counts"),
                String(localized: "Show a sample document from a collection"),
                String(localized: "Write an aggregation pipeline")
            ]
        case .bash:
            return [
                String(localized: "Scan for keys matching a pattern"),
                String(localized: "Check memory usage for a key"),
                String(localized: "List all keys by type")
            ]
        case .sql:
            return sqlSuggestions
        }
    }

    private static let sqlSuggestions: [String] = [
        String(localized: "Show tables and row counts"),
        String(localized: "Find the slowest queries"),
        String(localized: "Explain this table's structure")
    ]
}
