//
//  RowInspectorContext.swift
//  TablePro
//

import Foundation

// Everything the inspector draws. The assistant's context is separate, so a selection change never rebuilds it.
// The row's fields are not here: they live in `MultiRowEditState`.
internal struct RowInspectorContext: Equatable {
    internal let subject: InspectorSubject

    // Separate from the subject: a subject exists for a table with no row selected.
    internal let hasRow: Bool

    internal let isEditable: Bool
    internal let isRowDeleted: Bool

    // Only on a tab that has a table, so a query tab never shows the statistics of the last table opened.
    internal let tableMetadata: TableMetadata?

    // Raw cell values, because the JSON rendering quotes a value by its column's own type.
    internal let jsonRow: JSONRowSnapshot?

    // Set while a Structure view or a Create Table tab is on screen; the inspector then edits its definitions.
    internal var structure: StructureInspectorSource?

    internal static let empty = RowInspectorContext(
        subject: .empty,
        hasRow: false,
        isEditable: false,
        isRowDeleted: false,
        tableMetadata: nil,
        jsonRow: nil,
        structure: nil
    )
}

// The structure editor on screen, compared by identity. The inspector observes the editor itself, so a selection
// or an edit redraws it without a new context.
internal enum StructureInspectorSource: Equatable {
    case table(StructureEditingSession)
    case createTable(CreateTableDraft)

    internal static func == (lhs: StructureInspectorSource, rhs: StructureInspectorSource) -> Bool {
        switch (lhs, rhs) {
        case (.table(let left), .table(let right)): left === right
        case (.createTable(let left), .createTable(let right)): left === right
        default: false
        }
    }
}

internal struct AssistantContext: Equatable {
    internal let currentQuery: String?
    internal let queryResults: String?
    internal let editorTarget: AssistantEditorTarget?

    internal init(currentQuery: String?, queryResults: String?, editorTarget: AssistantEditorTarget? = nil) {
        self.currentQuery = currentQuery
        self.queryResults = queryResults
        self.editorTarget = editorTarget
    }

    internal static let empty = AssistantContext(currentQuery: nil, queryResults: nil)
}

internal struct AssistantEditorSnapshot: Equatable {
    internal let currentQuery: String?
    internal let target: AssistantEditorTarget?

    internal static let empty = AssistantEditorSnapshot(currentQuery: nil, target: nil)
}

internal struct AssistantEditorTarget: Equatable, Sendable {
    internal let tabId: UUID
    internal let scope: DatabaseScope?
    internal let errorMessage: String?
    internal let errorQuery: String?
}
