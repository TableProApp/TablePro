//
//  TableSelectionAction.swift
//  TablePro
//
//  Pure logic for deciding whether a sidebar selection change should trigger
//  navigation. Extracted so it can be unit-tested without any SwiftUI state.
//

import Foundation

/// Describes what should happen when the sidebar selection set changes.
///
/// Navigation follows a selection of one. Extending a selection is how a source list builds a batch
/// for Truncate, Delete or Export, so it must not also open a table, switch the session's database
/// and run a query. Requiring the resulting selection to be a single table keeps Cmd-click and
/// Shift-arrow out of the navigating path, which a delta on its own cannot do: adding one row to a
/// selection is still exactly one addition.
enum TableSelectionAction: Equatable {
    case noNavigation
    case navigate(table: TableInfo)

    /// `selectedRowCount` is how many rows the sidebar has selected, which the table set alone
    /// cannot tell: a table Cmd-clicked alongside a schema yields one table and is still an
    /// extension. Callers that can only ever select tables pass the table count.
    static func resolve(
        oldTables: Set<TableInfo>,
        newTables: Set<TableInfo>,
        selectedRowCount: Int
    ) -> TableSelectionAction {
        guard selectedRowCount == 1,
              newTables.count == 1,
              let table = SelectionDelta.singleAddition(old: oldTables, new: newTables)
        else {
            return .noNavigation
        }
        return .navigate(table: table)
    }
}

enum SelectionDelta {
    static func singleAddition<Element: Hashable>(
        old: Set<Element>,
        new: Set<Element>
    ) -> Element? {
        let added = new.subtracting(old)
        guard added.count == 1 else { return nil }
        return added.first
    }
}

/// Which object row the sidebar marks as the one this window has open.
///
/// The mark is document chrome: it names the table the selected tab is showing. The object tree
/// lists one container at a time, so the mark only means something while that tab's scope is the
/// scope being browsed. A tab bound to another database occupies no row here, and marking one
/// anyway picks a different table that merely shares a name, because `TableInfo` carries no
/// database to tell the two apart.
///
/// That is how a table opened in one database left the same-named row in another looking already
/// selected. `NSOutlineView` posts no selection change for a click on a row that is already the
/// whole selection, and the tree opens from that notification alone, so the click did nothing at
/// all and the table could not be opened in the second database (#2217).
enum SidebarObjectSelection: Equatable {
    /// The object list has not loaded, so there is no row to name yet and no answer to give.
    /// Clearing the mark here would blank it every time a container starts loading.
    case leaveUnchanged
    /// The rows the open document occupies, empty when it occupies none in the container on screen.
    case mark(Set<TableInfo>)

    /// - Parameters:
    ///   - tabScope: the selected tab's own scope, which it owns for life.
    ///   - browseScope: where the object tree is pointing.
    static func resolve(
        tabTableName: String?,
        tabScope: DatabaseScope?,
        browseScope: DatabaseScope?,
        tables: [TableInfo]
    ) -> SidebarObjectSelection {
        guard !tables.isEmpty else { return .leaveUnchanged }
        guard let tabTableName, !tabTableName.isEmpty, tabScope == browseScope,
              let match = tables.first(where: { $0.name == tabTableName })
        else {
            return .mark([])
        }
        return .mark([match])
    }
}
