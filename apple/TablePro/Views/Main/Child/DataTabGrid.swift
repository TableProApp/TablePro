//
//  DataTabGrid.swift
//  TablePro
//

import SwiftUI

// The data tab's grid. onChange runs the closure of the body from before a tab switch, so it reads only the
// presentation it is handed, which names its tab. Configuration is applied outside the update pass, since the model
// publishes when it changes.
struct DataTabGrid: View {
    let coordinator: MainContentCoordinator
    let model: DataGridModel
    let presentation: DataTabGridPresentation

    var body: some View {
        DataGridView(model: model)
            .id(presentation.tabId)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                coordinator.applyGridPresentation(presentation)
                focusIfRequested()
            }
            .onChange(of: presentation) { coordinator.applyGridPresentation($0) }
    }

    // An explicit open asks for the keyboard; the grid is in its window once this turn ends.
    private func focusIfRequested() {
        guard coordinator.consumePendingGridFocus() else { return }
        let model = model
        Task { @MainActor in
            model.focus()
        }
    }
}
