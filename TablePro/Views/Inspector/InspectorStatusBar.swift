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
        HStack(spacing: 10) {
            Text(rowSummary)
            separator
            Text(String(format: String(localized: "%d columns"), state.columnNames.count))
            if !state.selectedRowIndices.isEmpty {
                separator
                Text(String(format: String(localized: "%d selected"), state.selectedRowIndices.count))
            }
            if state.isComputing {
                separator
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Updating…"))
            }
            Spacer()
            if state.pageCount > 1 {
                pageControls
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button(action: onPreviousPage) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(state.pageOffset == 0)

            Text(String(format: String(localized: "Page %d of %d"), currentPage, state.pageCount))

            Button(action: onNextPage) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(currentPage >= state.pageCount)
        }
    }

    private var currentPage: Int {
        state.pageSize > 0 ? (state.pageOffset / state.pageSize) + 1 : 1
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private var rowSummary: String {
        if state.visibleRowCount == state.totalRowCount {
            return String(format: String(localized: "%d rows"), state.totalRowCount)
        }
        return String(
            format: String(localized: "%d of %d rows"),
            state.visibleRowCount,
            state.totalRowCount
        )
    }
}
