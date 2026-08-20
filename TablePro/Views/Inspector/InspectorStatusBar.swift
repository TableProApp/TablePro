//
//  InspectorStatusBar.swift
//  TablePro
//

import SwiftUI

struct InspectorStatusBar: View {
    @Bindable var state: InspectorViewState
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            rowSummary
            separator
            Text("\(state.columnNames.count) ^[columns](inflect: true)")
            if !state.selectedRowIndices.isEmpty {
                separator
                Text("\(state.selectedRowIndices.count) selected")
            }
            if state.isComputing {
                separator
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Updating…")
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

    /// Punctuation, so VoiceOver must not read it as an element of its own.
    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
