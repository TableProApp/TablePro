//
//  AIPromptTemplates.swift
//  TablePro
//
//  Centralized prompt formatting for AI editor integration features.
//

import Foundation
import TableProPluginKit

enum AIPromptTemplates {
    static func queryActionPrompt(
        _ action: AIQueryAction,
        statement: String,
        typeName: String,
        language: String,
        withStructure: Bool = true,
        errorMessage: String? = nil,
        explainPlan: String? = nil
    ) -> String {
        var prompt = action.instruction(typeName: typeName, withStructure: withStructure)
            + "\n\n" + MarkdownFence.wrap(statement, language: language)
        if action == .fixError, let errorMessage, !errorMessage.isEmpty {
            prompt += "\n\nError:\n" + MarkdownFence.wrap(errorMessage, language: "text")
        }
        if let explainPlan, !explainPlan.isEmpty {
            prompt += "\n\nExplain plan:\n" + MarkdownFence.wrap(explainPlan, language: "text")
        }
        return prompt
    }

    static func onDeviceQueryActionInstructions(engineName: String?, connectionRules: String?) -> String {
        var instructions = "You are the database assistant in TablePro, a database client. "
        if let engineName, !engineName.isEmpty {
            instructions += "The user's database is \(engineName); answer for its dialect. "
        }
        instructions += "Answer the request about the user's query briefly and in plain language. "
            + "Base every claim on the query and the table structure given, and say so when something you need is missing. "
            + "Put any SQL in a fenced code block."
        if let rules = connectionRules?.trimmingCharacters(in: .whitespacesAndNewlines), !rules.isEmpty {
            instructions += "\n\nRules for this connection:\n" + rules
        }
        return instructions
    }

    @MainActor static func queryInfo(for databaseType: DatabaseType) -> (typeName: String, language: String) {
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType)
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
