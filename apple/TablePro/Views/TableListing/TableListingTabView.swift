//
//  TableListingTabView.swift
//  TablePro
//

import SwiftUI

// Read-only and complete, so a header click sorts the rows on hand rather than re-running anything.
internal struct TableListingTabView: View {
    @ObservedObject var model: TableListingViewModel
    let databaseType: DatabaseType
    let kinds: [SidebarObjectKind]
    let kindTitle: (SidebarObjectKind) -> String
    let onSelectKind: (SidebarObjectKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ObjectListingBar(
                model: model,
                kinds: kinds,
                kindTitle: kindTitle,
                onSelectKind: onSelectKind
            )
            content
        }
        // Keyed by target: a retarget hands this view a fresh model that has not loaded yet.
        .task(id: model.target) { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        // Nothing is on its way, so a spinner would wait forever.
        case .idle where model.wasInterrupted:
            failure(String(localized: "The read stopped before it finished."))
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
        case .failed(let message):
            failure(message)
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

    private func failure(_ message: String) -> some View {
        UnavailableStateView {
            Label(model.target.kind.listingFailureTitle, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(String(localized: "Try Again")) {
                model.reload()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gridStandInBackground()
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
                UnavailableStateView(model.target.kind.listingEmptyTitle, systemImage: model.target.kind.iconName)
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
            .onAppear { model.grid.model.configuration = configuration(opensRows: model.rowsNameObjects) }
            .onChange(of: model.rowsNameObjects) { opensRows in
                model.grid.model.configuration = configuration(opensRows: opensRows)
            }
    }

    // A row that names an object opens it; a shell command's rows keep the cell viewer.
    private func configuration(opensRows: Bool) -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.traits = DataGridEngineTraits(databaseType: databaseType)
        configuration.showRowNumbers = true
        configuration.supportsValueFilter = false
        configuration.appliesRowCopyFormat = true
        configuration.commands = opensRows ? [.freezeColumns, .displayAs, .openRow] : [.freezeColumns, .displayAs]
        return configuration
    }
}
