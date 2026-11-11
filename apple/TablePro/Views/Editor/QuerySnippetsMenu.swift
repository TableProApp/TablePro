//
//  QuerySnippetsMenu.swift
//  TablePro
//

import SwiftUI

/// The two-row query bar's Snippets menu: the saved queries this connection can see, in their
/// folders, each inserted at the caret when chosen, with Save as Favorite at the bottom.
///
/// It reads the connection's `ConnectionDataCache`, the one the Favorites sidebar reads, so a query
/// saved or edited anywhere shows up here without a load of its own.
struct QuerySnippetsMenu: View {
    @ObservedObject var savedQueries: ConnectionDataCache
    let canSaveCurrentQuery: Bool
    let onInsert: (SQLFavorite) -> Void
    let onSaveCurrentQuery: () -> Void

    var body: some View {
        Menu {
            menuContent(QuerySnippetMenu.entries(folders: savedQueries.folders, favorites: savedQueries.favorites))
        } label: {
            Label(String(localized: "Snippets"), systemImage: "parentheses")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.visible)
        .controlSize(.small)
        .fixedSize()
        .help(String(localized: "Insert a saved query at the cursor"))
        .accessibilityIdentifier("query-snippets")
        .onAppear { savedQueries.ensureLoaded() }
    }

    /// Type-erased because a folder's submenu holds the same content one level down.
    private func menuContent(_ entries: [QuerySnippetMenuEntry]) -> AnyView {
        AnyView(ForEach(entries) { entry in
            switch entry {
            case .folder(let folder, let children):
                Menu(folder.name) { menuContent(children) }
            case .savedQuery(let favorite):
                Button(favorite.name) { onInsert(favorite) }
            case .empty:
                Button(String(localized: "No Saved Queries")) {}
                    .disabled(true)
            case .divider:
                Divider()
            case .saveCurrentQuery:
                Button(String(localized: "Save Current Query as Favorite…"), action: onSaveCurrentQuery)
                    .disabled(!canSaveCurrentQuery)
            }
        })
    }
}
