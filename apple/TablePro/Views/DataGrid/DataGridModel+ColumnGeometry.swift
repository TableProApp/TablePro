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
        let dataOrder = rows.columns
        updateColumnLayout { layout in
            // No stored order means data order; splicing into nothing kept only the shown names, which an ephemeral store drops.
            if order != nil, layout.columnOrder == nil, !dataOrder.isEmpty {
                layout.columnOrder = dataOrder
            }
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
