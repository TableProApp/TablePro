//
//  DataGridView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct DataGridView: View {
    @ObservedObject var model: DataGridModel

    init(model: DataGridModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            DataGridFindBarSlot(model: model, find: model.find)
            if model.configuration.fitsRows {
                DataGridRepresentable(model: model)
                    .frame(height: model.fittingHeight)
            } else {
                DataGridRepresentable(model: model)
            }
        }
    }
}

// Observes the find state alone, so typing in the find field never re-renders the grid.
private struct DataGridFindBarSlot: View {
    let model: DataGridModel
    @ObservedObject var find: GridFindState

    var body: some View {
        if find.isVisible {
            DataGridFindBar(model: model)
        }
    }
}

struct DataGridRepresentable: NSViewControllerRepresentable {
    let model: DataGridModel

    func makeNSViewController(context: Context) -> DataGridViewController {
        DataGridViewController(model: model)
    }

    func updateNSViewController(_ controller: DataGridViewController, context: Context) {
        controller.adopt(model)
    }

    // Commits an open edit before the grid goes, which covers a result-mode switch with no tab change.
    static func dismantleNSViewController(_ controller: DataGridViewController, coordinator: ()) {
        controller.dismantle()
    }
}
