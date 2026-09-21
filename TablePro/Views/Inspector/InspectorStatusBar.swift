//
//  InspectorStatusBar.swift
//  TablePro
//

import SwiftUI

struct InspectorStatusBar: View {
    @ObservedObject var state: InspectorViewState
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    /// Spacing alone separates the counts. A middle dot between them is punctuation the rest of the
    /// app's chrome no longer uses, and each count already reads as its own phrase.
    var body: some View {
        HStack(spacing: 14) {
            rowSummary
            Text("\(state.columnNames.count) ^[columns](inflect: true)")
            if !state.selectedRowIndices.isEmpty {
                Text("\(state.selectedRowIndices.count) selected")
            }
            if state.isComputing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Updating…")
                }
            }
            Spacer(minLength: 8)
            if state.pageCount > 1 {
                pageControls
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .statusBarChrome()
    }

    @ViewBuilder
    private var rowSummary: some View {
        if state.visibleRowCount == state.totalRowCount {
            Text("\(state.totalRowCount) ^[rows](inflect: true)")
        } else {
            Text("\(state.visibleRowCount) of \(state.totalRowCount) ^[rows](inflect: true)")
        }
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button(String(localized: "Previous page"), systemImage: "chevron.left", action: onPreviousPage)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(state.pageOffset == 0)

            Text("Page \(currentPage) of \(state.pageCount)")

            Button(String(localized: "Next page"), systemImage: "chevron.right", action: onNextPage)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(currentPage >= state.pageCount)
        }
    }

    private var currentPage: Int {
        state.pageSize > 0 ? (state.pageOffset / state.pageSize) + 1 : 1
    }
}
