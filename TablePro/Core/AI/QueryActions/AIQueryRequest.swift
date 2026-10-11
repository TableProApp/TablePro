//
//  AIQueryRequest.swift
//  TablePro
//

import Foundation

struct QueryEditorAnchor: Codable, Equatable, Hashable, Sendable {
    let tabId: UUID
    let location: Int?
    let length: Int?

    init(tabId: UUID, range: NSRange? = nil) {
        self.tabId = tabId
        self.location = range?.location
        self.length = range?.length
    }

    var range: NSRange? {
        guard let location, let length else { return nil }
        return NSRange(location: location, length: length)
    }
}

enum AIQueryTarget: Equatable, Sendable {
    case selectionOrStatementAtCursor
    case statement(containing: Int)

    static func contextMenu(selectedRange: NSRange, contextClickWord: NSRange?) -> AIQueryTarget {
        let selection = EditorContextSelection(selectedRange: selectedRange, contextClickWord: contextClickWord)
        guard selection.selectsOnlyClickedWord else { return .selectionOrStatementAtCursor }
        return .statement(containing: selection.effectiveRange.location)
    }
}

struct AIQueryRequest: Sendable {
    let action: AIQueryAction
    let statement: String
    let editorText: String?
    let scope: DatabaseScope?
    let databaseType: DatabaseType
    let source: QueryEditorAnchor?
    let errorMessage: String?
    let explainPlan: String?

    init(
        action: AIQueryAction,
        statement: String,
        editorText: String? = nil,
        scope: DatabaseScope?,
        databaseType: DatabaseType,
        source: QueryEditorAnchor? = nil,
        errorMessage: String? = nil,
        explainPlan: String? = nil
    ) {
        self.action = action
        self.statement = statement
        self.editorText = editorText
        self.scope = scope
        self.databaseType = databaseType
        self.source = source
        self.errorMessage = errorMessage
        self.explainPlan = explainPlan
    }

    var trimmedStatement: String {
        statement.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
