//
//  DataGridModelReader.swift
//  TablePro
//

import SwiftUI

// Re-renders its content when the model's selection or display order moves, for views outside the grid.
struct DataGridModelReader<Content: View>: View {
    @ObservedObject var model: DataGridModel
    @ViewBuilder let content: (DataGridModel) -> Content

    var body: some View {
        content(model)
    }
}

// Runs `onChange` for every selection change of the model, and once when it starts watching another one.
struct GridSelectionWatcher: View {
    @ObservedObject var model: DataGridModel
    let onAttach: () -> Void
    let onChange: (_ rowsChanged: Bool) -> Void
    @State private var selectedRowIDs: [RowID] = []

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                selectedRowIDs = model.selectedRowIDs
                onAttach()
            }
            .onChange(of: model.selectionRevision) { _ in
                let rowIDs = model.selectedRowIDs
                let rowsChanged = rowIDs != selectedRowIDs
                selectedRowIDs = rowIDs
                onChange(rowsChanged)
            }
    }
}
