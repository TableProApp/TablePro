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
        Picker(title, selection: shownSelection) {
            if allowsNone || columns.isEmpty {
                Text(noneLabel).tag(ResultChartColumnID?.none)
            }
            ForEach(columns) { column in
                Text(column.displayName).tag(Optional(column.id))
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// A pop-up shows nothing at all for a selection none of its items carries. A stored column
    /// missing from this result is kept for when it comes back, but the pop-up reads as the none
    /// item meanwhile, which is also what the chart is plotting.
    static func shownSelection(
        _ selection: ResultChartColumnID?,
        in columns: [ResultChartColumn]
    ) -> ResultChartColumnID? {
        guard let selection, columns.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }

    private var shownSelection: Binding<ResultChartColumnID?> {
        Binding(
            get: { Self.shownSelection(selection, in: columns) },
            set: { selection = $0 }
        )
    }
}
