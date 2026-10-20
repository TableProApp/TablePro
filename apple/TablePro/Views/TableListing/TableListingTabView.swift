//
//  TableListingTabView.swift
//  TablePro
//

import SwiftUI

/// The tables of one database or schema with what the engine knows about each, drawn by the app's own
/// data grid. Read-only and complete, so a header click sorts the rows on hand rather than re-running
/// anything, the way the agent result pane does.
internal struct TableListingTabView: View {
    @ObservedObject var model: TableListingViewModel
    let databaseType: DatabaseType

    var body: some View {
        content
            .task { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Can't List Tables"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    model.reload()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gridStandInBackground()
        case .loaded(let listing) where listing.rows.rows.isEmpty:
            emptyState(listing)
        case .loaded(let listing):
            VStack(spacing: 0) {
                grid(listing.rows)
                if let notice = listing.notice {
                    noticeBar(notice)
                }
            }
        }
    }

    /// A page with nothing on it is not an empty database when the driver says more pages follow.
    private func emptyState(_ listing: TableListing) -> some View {
        Group {
            if listing.isIncomplete {
                UnavailableStateView(
                    String(localized: "Nothing on This Page"),
                    systemImage: "ellipsis.rectangle",
                    description: listing.notice.map { Text($0) }
                )
            } else {
                UnavailableStateView(String(localized: "No Tables"), systemImage: "tablecells")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gridStandInBackground()
    }

    private func noticeBar(_ notice: String) -> some View {
        Label(notice, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .statusBarChrome()
    }

    private func grid(_ loaded: TableRows) -> some View {
        let rows = TableRowsSorting.sorted(loaded, by: model.sortState)
        return DataGridView(
            tableRowsProvider: { rows },
            changeManager: model.changeManager,
            isEditable: false,
            configuration: DataGridConfiguration(
                databaseType: databaseType,
                showRowNumbers: true,
                supportsColumnCommands: false,
                supportsValueFilter: false,
                appliesRowCopyFormat: true
            ),
            delegate: model.gridDelegate,
            selectedRowIndices: $model.selectedRows,
            sortState: $model.sortState,
            columnLayout: $model.columnLayout,
            contentRevision: contentRevision
        )
    }

    /// Moves whenever the rows the grid should draw move: a load lands, or a sort reorders them.
    private var contentRevision: Int {
        var hasher = Hasher()
        hasher.combine(model.revision)
        for column in model.sortState.columns {
            hasher.combine(column.columnIndex)
            hasher.combine(column.direction)
        }
        return hasher.finalize()
    }
}
