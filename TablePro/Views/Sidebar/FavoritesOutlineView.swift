//
//  FavoritesOutlineView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Everything the outline needs from `FavoritesTabView`, which keeps owning the row content, the
/// menus and the actions. Only the list container moved to AppKit.
internal struct FavoritesOutlineInput {
    internal let connectionId: UUID
    internal let activeDatabase: String?
    internal let tables: [TableInfo]
    internal let queryNodes: [FavoriteNode]
    internal let teamQueries: [FavoritesOutlineTeamQuery]
    internal let renamingFolderId: UUID?
    internal let allFolders: [SQLFavoriteFolder]
    internal let teamLibraryAvailable: Bool
}

internal struct FavoritesOutlineTeamQuery {
    internal let id: String
    internal let name: String
    internal let publishedBy: String?
}

/// Both actions carry the row's own kind rather than the persisted `FavoriteSelection`, because a
/// selection cannot name a Team Library row: those queries live outside the favorites tree and have
/// no `FavoriteNode` to look up.
internal struct FavoritesOutlineActions {
    internal let primaryAction: (FavoritesOutlineNode.Kind) -> Void
    internal let deleteSelection: (FavoritesOutlineNode.Kind) -> Void
    internal let commitRename: (SQLFavoriteFolder, String) -> Void
    internal let cancelRename: () -> Void
    /// Menu commands go back to the view, because several of them end in a confirmation the view
    /// owns. The menu itself stays a pure function of values either way.
    internal let performMenuCommand: (FavoritesMenuCommand) -> Void
}

/// The Favorites list as an `NSOutlineView`.
///
/// A SwiftUI `List` here could not draw an emphasized selection or answer an arrow key, because the
/// app hosts it in a bare `NSHostingController` with no SwiftUI scene above it. Rows stay SwiftUI:
/// AppKit publishes `NSTableCellView.backgroundStyle` into the hosted view's environment, so the
/// existing row content keeps working with no emphasis plumbing of its own.
internal struct FavoritesOutlineView<Row: View>: NSViewRepresentable {
    internal let input: FavoritesOutlineInput
    @Binding internal var selection: FavoriteSelection?
    internal let rowSizePreference: SidebarRowSizePreference
    internal let actions: FavoritesOutlineActions
    @ViewBuilder internal let row: (FavoritesOutlineNode) -> Row

    internal func makeCoordinator() -> FavoritesOutlineCoordinator<Row> {
        FavoritesOutlineCoordinator(owner: self)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let outlineView = FavoritesNSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FavoritesColumn",
                allowsMultipleSelection: false,
                rowSizePreference: rowSizePreference
            )
        )
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(FavoritesOutlineCoordinator<Row>.handleDoubleClick)
        outlineView.favoritesCoordinator = context.coordinator

        /// The table owns the menu, so AppKit sets `clickedRow`, draws the clicked-row highlight,
        /// and answers a right-click below the last row. The same shape the object list uses.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        context.coordinator.attach(outlineView: outlineView)
        return scrollView
    }

    internal func updateNSView(_ scrollView: NSScrollView, context: Context) {
        SidebarOutlineScaffold.applyRowSize(rowSizePreference, to: scrollView)
        context.coordinator.update(owner: self)
    }
}

/// Return commits, Delete removes. `NSOutlineView` routes neither on its own.
internal final class FavoritesNSOutlineView: SidebarOutlineView {
    internal weak var favoritesCoordinator: (any FavoritesOutlineKeyHandling)?

    override internal func insertNewline(_ sender: Any?) {
        favoritesCoordinator?.performPrimaryAction()
    }

    override internal func deleteBackward(_ sender: Any?) {
        favoritesCoordinator?.performDelete()
    }

    override internal func deleteForward(_ sender: Any?) {
        favoritesCoordinator?.performDelete()
    }
}

@MainActor
internal protocol FavoritesOutlineKeyHandling: AnyObject {
    func performPrimaryAction()
    func performDelete()
}
