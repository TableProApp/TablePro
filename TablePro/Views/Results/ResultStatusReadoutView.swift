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
///
/// The count the noun agrees with sits inside the `^[...](inflect: true)` span. Agreement reads
/// only the number the span encloses, so a count written before it still rendered "1 rows".
struct ResultStatusReadoutView: View {
    let readout: ResultStatusReadout

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("result-status-readout")
    }

    @ViewBuilder
    private var text: some View {
        switch readout {
        case .loading:
            /// Unlabelled, per the HIG: "Avoid labeling a spinning progress indicator." It stands in
            /// for the sentence rather than sitting beside one, so the readout has a single owner in
            /// every state and nothing is added to the row.
            ///
            /// Held back for the same reason it is unlabelled. A table on a local database answers
            /// in single-digit milliseconds, and a readout that spins for that long says less than
            /// the blank it replaces.
            LoadingReveal(isActive: true) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Loading…"))
            }
        case .noRows:
            Text("No rows")
        case let .rowCount(count):
            Text("^[\(count) row](inflect: true)")
        case let .partialLoad(count):
            Text("Showing ^[\(count) row](inflect: true)")
        case let .range(start, end, total, isEstimate):
            if isEstimate {
                Text("\(start)-\(end) of ~^[\(total) row](inflect: true)")
            } else {
                Text("\(start)-\(end) of ^[\(total) row](inflect: true)")
            }
        case let .rangeOfUnknownTotal(start, end):
            Text("Rows \(start)-\(end)")
        case let .valueFiltered(shown, loaded):
            Text("Filtered to \(shown) of ^[\(loaded) row](inflect: true)")
        case let .selection(selected, total):
            Text("\(selected) of ^[\(total) row](inflect: true) selected")
        case let .allSelected(count):
            Text("All ^[\(count) row](inflect: true) selected")
        }
    }
}
