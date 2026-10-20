import SwiftUI

enum SavedQueriesSheetRoute: Identifiable, Hashable {
    case list
    case save(sql: String)

    var id: String {
        switch self {
        case .list:
            "list"
        case .save:
            "save"
        }
    }
}

struct SavedQueriesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let route: SavedQueriesSheetRoute
    let connectionId: UUID
    @Binding var expandedFolderIds: Set<UUID>
    let onOpen: (String) -> Void

    var body: some View {
        NavigationStack {
            switch appState.savedQueries.status {
            case .ready:
                content
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Saved Queries")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { closeItem }
            case .failed:
                unavailableView
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            SavedQueryListView(connectionId: connectionId, expandedFolderIds: $expandedFolderIds) { sql in
                onOpen(sql)
                dismiss()
            }
        case .save(let sql):
            SavedQueryFormView(newQuery: sql, connectionId: connectionId)
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("Saved Queries Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("TablePro could not read your saved queries. Nothing on this device has been changed.")
        } actions: {
            Button("Try Again") {
                appState.savedQueries.retryLoadIfFailed()
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Saved Queries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeItem }
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            CloseButton { dismiss() }
        }
    }
}

extension View {
    func savedQueryWriteFailureAlert(_ failure: Binding<SavedQueryWriteFailure?>) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if !$0 { failure.wrappedValue = nil } }
            ),
            presenting: failure.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { presented in
            Text(presented.message)
        }
    }
}
