import SwiftUI

struct HistoryListPane: View {
    @Bindable var viewModel: HistoryPanelViewModel

    let canRunInNewTab: (QueryHistoryEntry) -> Bool
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

    /// A history is read by arrowing through it, so the list owns the keyboard: selecting a row
    /// leaves focus here, and only Return or a double-click sends the query to the editor.
    private var entryList: some View {
        FieldDrivenList(
            sections: viewModel.sections.map { section in
                FieldDrivenListSection(
                    id: String(section.day.timeIntervalSince1970),
                    title: QueryHistoryGrouping.title(for: section.day),
                    items: section.entries
                )
            },
            selection: selectionBinding,
            rowHeight: 44,
            onPrimaryAction: { id in
                guard let entry = entry(id) else { return }
                onLoadInEditor(entry)
            },
            menuItems: { ids in menuItems(for: ids) },
            acceptsFocus: true,
            onDeleteCommand: { Task { await viewModel.deleteSelection() } },
            onCopyCommand: {
                guard let entry = viewModel.selectedEntry else { return }
                onCopy(entry)
            },
            accessibilityIdentifier: "query-history-list",
            row: { entry in
                HistoryRowView(entry: entry, connectionLabel: viewModel.connectionLabel(for: entry))
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.hasMore {
                loadMoreBar
            }
        }
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { viewModel.selectedEntryId.map { [$0] } ?? [] },
            set: { viewModel.selectedEntryId = $0.first }
        )
    }

    private func entry(_ id: UUID) -> QueryHistoryEntry? {
        viewModel.sections.lazy.flatMap(\.entries).first { $0.id == id }
    }

    private var loadMoreBar: some View {
        VStack(spacing: 0) {
            Divider()
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
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        Group {
            if viewModel.isStoreUnavailable {
                ContentUnavailableView {
                    Label(String(localized: "Query History Is Unavailable"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text("TablePro could not open its query history database, so nothing is being recorded and nothing can be shown. Your existing history is still on disk.")
                }
            } else if viewModel.state.hasNarrowingFilter {
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

    private func menuItems(for ids: Set<UUID>) -> [FieldDrivenMenuItem] {
        guard let id = ids.first, let entry = entry(id) else { return [] }
        return [
            FieldDrivenMenuItem(title: String(localized: "Load in Editor")) { onLoadInEditor(entry) },
            FieldDrivenMenuItem(
                title: String(localized: "Run in New Tab"),
                isEnabled: canRunInNewTab(entry)
            ) { onRunInNewTab(entry) },
            .separator,
            FieldDrivenMenuItem(title: String(localized: "Copy Query")) { onCopy(entry) },
            FieldDrivenMenuItem(title: String(localized: "Save as Favorite…")) { onSaveAsFavorite(entry) },
            .separator,
            FieldDrivenMenuItem(title: String(localized: "Delete")) {
                Task { await viewModel.delete(entry) }
            }
        ]
    }
}
