//
//  ResultChartAxisPicker.swift
//  TablePro
//

import SwiftUI

struct ResultChartAxisPicker: View {
    let title: String
    @Binding var selection: ResultChartColumnID?
    let columns: [ResultChartColumn]
    let noneLabel: String
    /// The Y axis has no "no column" state while any numeric column exists, because the chart falls
    /// back to a default. Offering the row anyway gives a choice that silently re-plots something
    /// else, so it appears only when there is genuinely nothing to choose.
    let allowsNone: Bool
    let accessibilityIdentifier: String

    var body: some View {
        Picker(title, selection: $selection) {
            if allowsNone || columns.isEmpty {
                Text(noneLabel).tag(ResultChartColumnID?.none)
            }
            ForEach(columns) { column in
                Text(column.displayName).tag(Optional(column.id))
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
