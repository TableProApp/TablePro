import AppKit
import SwiftUI

struct HistoryPanelView: View {
    let connectionId: UUID

    @Environment(\.appServices) private var services
    @FocusedValue(\.commandActions) private var actions

    @State private var viewModel: HistoryPanelViewModel?
    @State private var favoriteDialogQuery: FavoriteDialogQuery?

    var body: some View {
        Group {
            if let viewModel {
                panel(viewModel)
            } else {
                Color.clear
            }
        }
        .task(id: connectionId) {
            let model = viewModel ?? HistoryPanelViewModel(connectionId: connectionId, services: services)
            viewModel = model
            model.startObserving()
            await model.reload()
        }
        .onDisappear {
            viewModel?.stopObserving()
        }
        .sheet(item: $favoriteDialogQuery) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: nil,
                initialQuery: item.query,
                folders: []
            )
        }
    }

    private func panel(_ viewModel: HistoryPanelViewModel) -> some View {
        AutosavingSplitView(
            autosaveName: "com.TablePro.queryHistory.listDetail",
            primaryMinimum: 260,
            secondaryMinimum: 280,
            collapsesPrimaryWhenTight: false
        ) {
            HistoryListPane(
                viewModel: viewModel,
                onLoadInEditor: { load($0) },
                onRunInNewTab: { runInNewTab($0) },
                onCopy: { copy($0) },
                onSaveAsFavorite: { favoriteDialogQuery = FavoriteDialogQuery(query: $0.query) }
            )
        } secondary: {
            HistoryDetailPane(
                entry: viewModel.selectedEntry,
                connectionLabel: viewModel.selectedEntry.flatMap { viewModel.connectionLabel(for: $0) },
                onLoadInEditor: { load($0) },
                onRunInNewTab: { runInNewTab($0) },
                onCopy: { copy($0) }
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HistoryPanelToolbar(viewModel: viewModel, state: viewModel.state)
        }
    }

    private func load(_ entry: QueryHistoryEntry) {
        guard entry.connectionId == connectionId else {
            actions?.newTab(initialQuery: entry.query)
            return
        }
        actions?.loadQueryIntoEditor(entry.query)
    }

    private func runInNewTab(_ entry: QueryHistoryEntry) {
        actions?.newTab(initialQuery: entry.query)
    }

    private func copy(_ entry: QueryHistoryEntry) {
        ClipboardService.shared.writeText(entry.query)
    }
}
