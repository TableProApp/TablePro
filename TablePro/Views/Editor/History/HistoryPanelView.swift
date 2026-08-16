import AppKit
import SwiftUI

struct HistoryPanelView: View {
    /// Held directly rather than resolved from a focused value. The app runs the AppKit lifecycle
    /// with no SwiftUI `Scene`, so `focusedSceneValue` has nothing to publish into and every action
    /// that read one was silently dead. Every other call site in the app reaches actions this way.
    let coordinator: MainContentCoordinator

    @Environment(\.appServices) private var services

    @State private var viewModel: HistoryPanelViewModel?
    @State private var favoriteDialogQuery: FavoriteDialogQuery?

    private var connectionId: UUID { coordinator.connectionId }

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
                canRunInNewTab: { canRun($0) },
                onLoadInEditor: { load($0) },
                onRunInNewTab: { runInNewTab($0) },
                onCopy: { copy($0) },
                onSaveAsFavorite: { favoriteDialogQuery = FavoriteDialogQuery(query: $0.query) }
            )
        } secondary: {
            HistoryDetailPane(
                entry: viewModel.selectedEntry,
                connectionLabel: viewModel.selectedEntry.flatMap { viewModel.connectionLabel(for: $0) },
                canRunInNewTab: viewModel.selectedEntry.map { canRun($0) } ?? false,
                onLoadInEditor: { load($0) },
                onRunInNewTab: { runInNewTab($0) },
                onCopy: { copy($0) }
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HistoryPanelToolbar(viewModel: viewModel, state: viewModel.state)
        }
    }

    /// Running belongs to the connection that recorded the query, and this window only drives its
    /// own. A foreign entry still loads, into that connection's window, where the user runs it.
    private func canRun(_ entry: QueryHistoryEntry) -> Bool {
        entry.connectionId == connectionId
    }

    private func load(_ entry: QueryHistoryEntry) {
        coordinator.openQuery(
            entry.query,
            on: entry.connectionId,
            databaseName: entry.databaseName,
            intent: .loadIntoFrontTab
        )
    }

    private func runInNewTab(_ entry: QueryHistoryEntry) {
        guard canRun(entry) else { return }
        coordinator.openQuery(
            entry.query,
            on: entry.connectionId,
            databaseName: entry.databaseName,
            intent: .runInNewTab
        )
    }

    private func copy(_ entry: QueryHistoryEntry) {
        ClipboardService.shared.writeText(entry.query)
    }
}
