//
//  BindingCommittingGridEditTests.swift
//  TableProTests
//

import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct BindingCommittingGridEditTests {
    @MainActor
    private final class Selection {
        var tab = "columns"
    }

    @Test("A tab change commits the open edit while the pane being left is still selected")
    func commitsBeforePublishing() {
        let model = DataGridModel(configuration: DataGridConfiguration())
        let grid = DataTabGridMountStub()
        grid.isEditing = true
        model.attach(grid)
        let selection = Selection()
        var tabAtCommit: String?
        grid.onCommit = { tabAtCommit = selection.tab }
        let binding = Binding(get: { selection.tab }, set: { selection.tab = $0 }).committingEdit(of: model)

        binding.wrappedValue = "indexes"

        #expect(tabAtCommit == "columns")
        #expect(selection.tab == "indexes")
        #expect(grid.commitCount == 1)
        #expect(!grid.isEditing)
    }

    @Test("With no grid mounted the tab still changes")
    func changesWithoutAGrid() {
        let model = DataGridModel(configuration: DataGridConfiguration())
        let selection = Selection()
        let binding = Binding(get: { selection.tab }, set: { selection.tab = $0 }).committingEdit(of: model)

        binding.wrappedValue = "indexes"

        #expect(selection.tab == "indexes")
    }
}
