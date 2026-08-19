//
//  ResultChartAxisPicker.swift
//  TablePro
//

import SwiftUI

struct ResultChartAxisPicker: View {
    let title: String
    @Binding var selection: Int?
    let columns: [ResultChartColumn]
    let noneLabel: String
    let accessibilityIdentifier: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(noneLabel).tag(Int?.none)
            ForEach(columns) { column in
                Text(column.displayName).tag(Optional(column.index))
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
