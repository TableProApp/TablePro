//
//  AIPromptTemplates+Walkthrough.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension AIPromptTemplates {
    @MainActor static func explainQueryWalkthrough(_ query: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = walkthroughQueryInfo(for: databaseType)
        return explainQueryWalkthrough(query, typeName: typeName, language: lang)
    }

    @MainActor static func optimizeQueryWalkthrough(_ query: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = walkthroughQueryInfo(for: databaseType)
        return optimizeQueryWalkthrough(query, typeName: typeName, language: lang)
    }

    @MainActor static func fixErrorWalkthrough(query: String, error: String, databaseType: DatabaseType = .mysql) -> String {
        let (typeName, lang) = walkthroughQueryInfo(for: databaseType)
        return fixErrorWalkthrough(query: query, error: error, typeName: typeName, language: lang)
    }

    static func explainQueryWalkthrough(_ query: String, typeName: String, language: String) -> String {
        """
        Explain this \(typeName):

        ```\(language)
        \(query)
        ```

        Write a short plain-language explanation. Then output the walkthrough block described below.
        \(envelopeInstructions(hasRewrite: false))
        """
    }

    static func optimizeQueryWalkthrough(_ query: String, typeName: String, language: String) -> String {
        """
        Optimize this \(typeName) for better performance and return the improved version:

        ```\(language)
        \(query)
        ```

        Keep the result equivalent. Then output the walkthrough block described below.
        \(envelopeInstructions(hasRewrite: true))
        """
    }

    static func fixErrorWalkthrough(query: String, error: String, typeName: String, language: String) -> String {
        """
        This \(typeName) failed with an error. Fix it and return the corrected version.

        Query:
        ```\(language)
        \(query)
        ```

        Error: \(error)

        Then output the walkthrough block described below.
        \(envelopeInstructions(hasRewrite: true))
        """
    }

    private static func envelopeInstructions(hasRewrite: Bool) -> String {
        let afterField = hasRewrite
            ? "Set \"afterSQL\" to the full rewritten query."
            : "Set \"afterSQL\" to null (no rewrite)."
        return """

        After the explanation, output one block delimited by the exact markers below
        with valid JSON between them. Do not output a diff; the app builds the diff from
        your afterSQL. Anchor each step to the 1-based line numbers it refers to, and omit
        "anchor" if a step is about the whole query. Keep each step to one short sentence.

        \(WalkthroughEnvelopeParser.openFence)
        {
          "afterSQL": null,
          "steps": [
            {
              "title": "short label",
              "why": "one sentence",
              "importance": "critical | normal | context",
              "changeType": "addition | removal | modification | explanation",
              "anchor": { "side": "before | after | both", "startLine": 1, "endLine": 1 }
            }
          ]
        }
        \(WalkthroughEnvelopeParser.closeFence)

        \(afterField)
        """
    }

    @MainActor private static func walkthroughQueryInfo(for databaseType: DatabaseType) -> (typeName: String, language: String) {
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
