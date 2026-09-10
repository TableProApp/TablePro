//
//  ResultChartTypePicker.swift
//  TablePro
//

import SwiftUI

struct ResultChartTypePicker: View {
    @Binding var selection: ResultChartType

    var body: some View {
        Picker(String(localized: "Chart Type"), selection: $selection) {
            ForEach(ResultChartType.allCases) { type in
                Label(type.displayName, systemImage: type.systemImage)
                    .tag(type)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("result-chart-type-picker")
    }
}
