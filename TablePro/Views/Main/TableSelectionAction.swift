//
//  TableSelectionAction.swift
//  TablePro
//
//  Pure logic for deciding whether a sidebar selection change should trigger
//  navigation. Extracted so it can be unit-tested without any SwiftUI state.
//

import Foundation
import TableProPluginKit

/// Describes what should happen when the sidebar selection set changes.
///
/// Navigation follows a selection of one. Extending a selection is how a source list builds a batch
/// for Truncate, Delete or Export, so it must not also open a table, switch the session's database
/// and run a query. Requiring the resulting selection to be a single table keeps Cmd-click and
/// Shift-arrow out of the navigating path, which a delta on its own cannot do: adding one row to a
/// selection is still exactly one addition.
enum TableSelectionAction: Equatable {
    case noNavigation
    case navigate(ref: DatabaseTreeTableRef)

    /// `selectedRowCount` is how many rows the sidebar has selected, which the table set alone
    /// cannot tell: a table Cmd-clicked alongside a schema yields one table and is still an
    /// extension. Callers that can only ever select tables pass the table count.
    static func resolve(
        oldTables: Set<DatabaseTreeTableRef>,
        newTables: Set<DatabaseTreeTableRef>,
        selectedRowCount: Int
    ) -> TableSelectionAction {
        guard selectedRowCount == 1,
              newTables.count == 1,
              let ref = SelectionDelta.singleAddition(old: oldTables, new: newTables)
        else {
            return .noNavigation
        }
        return .navigate(ref: ref)
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
/// lists one database at a time, so the mark only means something while the selected tab is in
/// that database. A tab bound to another one occupies no row here, and marking it anyway picks a
/// different table that merely shares a name, because `TableInfo` carries no database to tell the
/// two apart.
///
/// That is how a table opened in one database left the same-named row in another looking already
/// selected. `NSOutlineView` posts no selection change for a click on a row that is already the
/// whole selection, and the tree opens from that notification alone, so the click did nothing at
/// all and the table could not be opened in the second database (#2217).
///
/// The schema is a tie-break rather than a second gate. Engines that group by schema list every
/// schema of the database at once, so `public.orders` keeps its row while the browse cursor is on
/// `reporting`, and gating on the schema too would unmark a row the user can see.
enum SidebarObjectSelection: Equatable {
    /// The object list has not loaded, so there is no row to name yet and no answer to give.
    /// Clearing the mark here would blank it every time a container starts loading.
    case leaveUnchanged
    /// The rows the open document occupies, empty when it occupies none in the database on screen.
    case mark(Set<DatabaseTreeTableRef>)

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
        guard let tabTableName, !tabTableName.isEmpty,
              let tabScope, let browseScope,
              tabScope.database == browseScope.database,
              let match = tables.first(where: { row($0, is: tabTableName, in: tabScope.schema) })
        else {
            return .mark([])
        }
        /// Spelled the way the tree spells its own rows, or the mark names a row the tree does not
        /// have. A tree hangs a table off a schema node and the row's own schema may be empty
        /// there, so the tab's schema stands in; the database is the browsed one, which is the
        /// only database whose rows are on screen.
        return .mark([DatabaseTreeTableRef(
            database: browseScope.database.nilIfEmpty,
            schema: match.schema?.nilIfEmpty ?? tabScope.schema,
            table: match
        )])
    }

    /// A schema decides between two rows only when both sides name one. An engine without schemas
    /// leaves every row's schema empty, and one that lists a single schema at a time can only offer
    /// rows from it, so in both cases the name is already the whole answer.
    private static func row(_ table: TableInfo, is name: String, in schema: String?) -> Bool {
        guard table.name == name else { return false }
        guard let schema, !schema.isEmpty,
              let rowSchema = table.schema, !rowSchema.isEmpty else { return true }
        return rowSchema == schema
    }
}
