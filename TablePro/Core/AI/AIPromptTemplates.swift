//
//  AIPromptTemplates.swift
//  TablePro
//
//  Centralized prompt formatting for AI editor integration features.
//

import Foundation
import TableProPluginKit

/// Centralized prompt templates for AI-powered editor features
enum AIPromptTemplates {
    /// Build a prompt asking AI to explain a query
    @MainActor static func explainQuery(_ query: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = queryInfo(for: databaseType)
        return explainQuery(query, typeName: typeName, language: lang)
    }

    /// Build a prompt asking AI to optimize a query
    @MainActor static func optimizeQuery(_ query: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = queryInfo(for: databaseType)
        return optimizeQuery(query, typeName: typeName, language: lang)
    }

    /// Build a prompt asking AI to fix a query that produced an error
    @MainActor static func fixError(query: String, error: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = queryInfo(for: databaseType)
        return fixError(query: query, error: error, typeName: typeName, language: lang)
    }

    // MARK: - Non-isolated overloads

    static func explainQuery(_ query: String, typeName: String, language: String) -> String {
        "Explain this \(typeName):\n\n```\(language)\n\(query)\n```"
    }

    static func optimizeQuery(_ query: String, typeName: String, language: String) -> String {
        "Optimize this \(typeName) for better performance:\n\n```\(language)\n\(query)\n```"
    }

    static func fixError(query: String, error: String, typeName: String, language: String) -> String {
        "This \(typeName) failed with an error. Please fix it.\n\nQuery:\n```\(language)\n\(query)\n```\n\nError: \(error)"
    }

    @MainActor private static func queryInfo(for databaseType: DatabaseType) -> (typeName: String, language: String) {
        let snapshot = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)
        let editorLanguage = snapshot?.editorLanguage ?? .sql
        let lang = editorLanguage.codeBlockTag
        let typeName: String
        switch editorLanguage {
        case .sql:
            typeName = "\(snapshot?.queryLanguageName ?? "SQL") query"
        case .bash:
            typeName = "\(snapshot?.displayName ?? databaseType.rawValue) command"
        case .javascript:
            typeName = "\(snapshot?.displayName ?? databaseType.rawValue) query"
        case .custom:
            typeName = "\(snapshot?.displayName ?? databaseType.rawValue) query"
        }
        return (typeName, lang)
    }
}
