//
//  TableListingTabView.swift
//  TablePro
//

import SwiftUI

// Read-only and complete, so a header click sorts the rows on hand rather than re-running anything.
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
                rowsGrid
                if let notice = listing.notice {
                    noticeBar(notice)
                }
            }
        }
    }

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

    private var rowsGrid: some View {
        DataGridView(model: model.grid.model)
            .onAppear { model.grid.model.configuration = configuration }
    }

    private var configuration: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: databaseType)
        configuration.showRowNumbers = true
        configuration.supportsValueFilter = false
        configuration.appliesRowCopyFormat = true
        configuration.commands = [.freezeColumns, .displayAs]
        return configuration
    }
}
