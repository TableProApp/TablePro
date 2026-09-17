//
//  View+ChartSelectionCompat.swift
//  TablePro
//

import Charts
import SwiftUI

internal extension View {
    /// `chartXSelection` is macOS 14. Before it a chart could not report a selection back, so
    /// the binding simply never fires and the callout never appears; the chart still draws.
    @ViewBuilder
    func chartXSelectionCompat<Value: Plottable>(value: Binding<Value?>) -> some View {
        if #available(macOS 14.0, *) {
            chartXSelection(value: value)
        } else {
            self
        }
    }
}
