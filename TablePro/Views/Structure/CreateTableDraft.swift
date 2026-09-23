//
//  CreateTableDraft.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

/// A table definition in progress, held outside the view that edits it.
///
/// A Create Table tab's whole content is unsaved by definition: nothing exists on the server until
/// the user presses Create. `MainEditorContentView` builds only the selected tab, so leaving the
/// definition in the view's `@State` meant switching to any other tab and back threw away the table
/// name, the options and every column the user had defined, with no prompt and nothing in Undo.
@MainActor
internal final class CreateTableDraft: ObservableObject {
    internal let changeManager = StructureChangeManager()

    /// A new name answers whatever the driver said about the last one, so its error goes with it.
    @Published internal var tableName = "" {
        didSet {
            guard tableName != oldValue else { return }
            form?.clearSubmissionError()
        }
    }
    @Published internal var tableOptions = CreateTableOptions()
    @Published internal var form: CreateTableFormState?
    @Published internal private(set) var hasResolvedForm = false

    internal func resolveForm(from spec: @autoclosure () -> PluginCreateTableFormSpec?) {
        guard !hasResolvedForm else { return }
        hasResolvedForm = true
        form = spec().map(CreateTableFormState.init(spec:))
    }

    /// Whether the draft holds anything worth losing. A tab that has only just opened does not: the
    /// editor seeds one blank column so the grid has a row to show, which registers as a pending
    /// change without the user having typed anything.
    ///
    /// Indexes and foreign keys count for the same reason columns do. While they did not, a tab
    /// holding nothing but foreign keys closed on Cmd+W with no prompt and the draft was dropped.
    internal var holdsWork: Bool {
        !tableName.isEmpty
            || form?.holdsWork == true
            || changeManager.workingColumns.contains { !$0.name.isEmpty }
            || changeManager.workingIndexes.contains { !$0.name.isEmpty || !$0.columns.isEmpty }
            || changeManager.workingForeignKeys.contains {
                !$0.name.isEmpty || !$0.columns.isEmpty || !$0.referencedTable.isEmpty
            }
    }
}
