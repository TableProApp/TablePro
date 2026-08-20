//
//  ResultStatusReadoutView.swift
//  TablePro
//

import SwiftUI

/// The sentence describing the rows on screen.
///
/// One catalog key per case, with the numbers as `%lld` arguments so they group per locale and the
/// noun inflects with the count. The previous shape assembled one sentence out of seven independent
/// keys through `String(format:)`, which never groups and cannot select a plural variant, so it
/// rendered "1 rows" and put an ungrouped range next to a grouped total in the same breath.
struct ResultStatusReadoutView: View {
    let readout: ResultStatusReadout

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityIdentifier("result-status-readout")
    }

    @ViewBuilder
    private var text: some View {
        switch readout {
        case .noRows:
            Text("No rows")
        case let .rowCount(count):
            Text("\(count) ^[rows](inflect: true)")
        case let .partialLoad(count):
            Text("Showing \(count) ^[rows](inflect: true)")
        case let .range(start, end, total, isEstimate):
            if isEstimate {
                Text("\(start)-\(end) of ~\(total) ^[rows](inflect: true)")
            } else {
                Text("\(start)-\(end) of \(total) ^[rows](inflect: true)")
            }
        case let .rangeOfUnknownTotal(start, end):
            Text("Rows \(start)-\(end)")
        case let .valueFiltered(shown, loaded):
            Text("Filtered to \(shown) of \(loaded) ^[rows](inflect: true)")
        case let .selection(selected, total):
            Text("\(selected) of \(total) ^[rows](inflect: true) selected")
        case let .allSelected(count):
            Text("All \(count) ^[rows](inflect: true) selected")
        }
    }
}
