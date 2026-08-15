import SwiftUI

struct HistoryListPane: View {
    @Bindable var viewModel: HistoryPanelViewModel

    let onLoadInEditor: (QueryHistoryEntry) -> Void
    let onRunInNewTab: (QueryHistoryEntry) -> Void
    let onCopy: (QueryHistoryEntry) -> Void
    let onSaveAsFavorite: (QueryHistoryEntry) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, !viewModel.hasLoadedOnce {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isEmpty {
            emptyState
        } else {
            entryList
        }
    }

    private var entryList: some View {
        List(selection: $viewModel.selectedEntryId) {
            ForEach(viewModel.sections) { section in
                Section(QueryHistoryGrouping.title(for: section.day)) {
                    ForEach(section.entries) { entry in
                        HistoryRowView(entry: entry, connectionLabel: viewModel.connectionLabel(for: entry))
                            .tag(entry.id)
                            .contextMenu { menu(for: entry) }
                    }
                }
            }

            if viewModel.hasMore {
                loadMoreRow
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .accessibilityIdentifier("query-history-list")
        .onDeleteCommand {
            Task { await viewModel.deleteSelection() }
        }
        .onCopyCommand {
            guard let entry = viewModel.selectedEntry else { return [] }
            onCopy(entry)
            return []
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            Button {
                Task { await viewModel.loadMore() }
            } label: {
                if viewModel.isLoadingMore {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Load More")
                }
            }
            .buttonStyle(.link)
            .disabled(viewModel.isLoadingMore)
            .accessibilityIdentifier("query-history-load-more")
            Spacer()
        }
        .selectionDisabled()
    }

    private var emptyState: some View {
        Group {
            if viewModel.state.hasNarrowingFilter {
                ContentUnavailableView {
                    Label(String(localized: "No Matching Queries"), systemImage: "magnifyingglass")
                } description: {
                    Text("No query matches the current search and filters.")
                } actions: {
                    Button(String(localized: "Reset Filters")) {
                        viewModel.state.resetFilters()
                        Task { await viewModel.reload() }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Query History"), systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Queries you run appear here.")
                }
            }
        }
        .accessibilityIdentifier("query-history-empty")
    }

    @ViewBuilder
    private func menu(for entry: QueryHistoryEntry) -> some View {
        Button(String(localized: "Load in Editor")) { onLoadInEditor(entry) }
        Button(String(localized: "Run in New Tab")) { onRunInNewTab(entry) }
        Divider()
        Button(String(localized: "Copy Query")) { onCopy(entry) }
        Button(String(localized: "Save as Favorite…")) { onSaveAsFavorite(entry) }
        Divider()
        Button(String(localized: "Delete")) {
            Task { await viewModel.delete(entry) }
        }
    }
}
