//
//  DataGridModel+ColumnGeometry.swift
//  TablePro
//

import Foundation

extension DataGridModel {
    // A resize, move or size-to-fit the user made in the grid. Widths given here are the user's, so they are recorded as
    // owned; the order splices into the stored one so a hidden column keeps its slot.
    func columnGeometryDidChange(widths: [String: CGFloat], order: [String]?) {
        guard !widths.isEmpty || order != nil else { return }
        updateColumnLayout { layout in
            var captured = layout
            captured.columnWidths.merge(widths) { _, new in new }
            if !widths.isEmpty {
                var owned = captured.columnContentWidths ?? [:]
                owned.merge(widths) { _, new in new }
                captured.columnContentWidths = owned
            }
            if let order {
                captured.columnOrder = order
            }
            layout.applyGeometry(from: captured)
        }
    }
}
