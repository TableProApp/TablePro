//
//  QueryTimingBreakdown.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The rows a timing popover shows, resolved once so the view and its tests read the same list.
///
/// Kept apart from the view because what is worth showing depends on what the driver could measure,
/// and that decision is the part worth pinning with a test.
struct QueryTimingBreakdown: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
    }

    let rows: [Row]
    let summary: String

    init(timing: PluginQueryTiming) {
        var rows: [Row] = [
            Row(
                id: "elapsed",
                label: String(localized: "Elapsed"),
                value: QueryDurationFormatter.string(from: timing.total)
            ),
        ]

        if let server = timing.server {
            rows.append(Row(
                id: "server",
                label: String(localized: "Server"),
                value: QueryDurationFormatter.string(from: server)
            ))
        }
        if let firstRow = timing.firstRow {
            rows.append(Row(
                id: "firstRow",
                label: String(localized: "First row"),
                value: QueryDurationFormatter.string(from: firstRow)
            ))
        }
        if let transfer = timing.transfer {
            rows.append(Row(
                id: "transfer",
                label: String(localized: "Transfer"),
                value: QueryDurationFormatter.string(from: transfer)
            ))
        }

        self.rows = rows
        summary = rows.map { "\($0.label) \($0.value)" }.joined(separator: " · ")
    }
}

/// The popover behind the toolbar's duration readout.
struct QueryTimingPopover: View {
    let breakdown: QueryTimingBreakdown
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(breakdown.rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.system(.body, design: .monospaced))
                            .gridColumnAlignment(.trailing)
                    }
                }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(14)
        .accessibilityIdentifier("query-timing-popover")
    }
}
