//
//  Binding+CommittingGridEdit.swift
//  TablePro
//

import SwiftUI

extension Binding {
    /// For a tab view whose panes share one grid model. The open cell edit commits against the pane
    /// being left before the new tab is published, because the incoming pane's grid can mount before
    /// the outgoing one is dismantled, and an edit committed at that teardown would land on the new
    /// pane's rows, which reuse the same row and column ids.
    @MainActor
    func committingEdit(of model: DataGridModel) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                model.commitEditing()
                wrappedValue = newValue
            }
        )
    }
}
