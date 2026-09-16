//
//  TableOperationEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which objects a table operation may be aimed at.
///
/// The single answer for both menus that offer Truncate. Deciding it in two places let them
/// disagree, and the menu bar's copy asked only whether anything was selected, so it staged a
/// `TRUNCATE` against a view. It sits beside the models because the menu-bar validator in `Core/`
/// has to reach it and must not depend on a `Views/` file.
enum TableOperationEligibility {
    /// What the connection's engine can express, alongside what the object's kind allows.
    ///
    /// Kind alone was the whole test, so both items were offered on every engine and an
    /// Elasticsearch index was handed `DROP TABLE "test_index"` (#2884). The driver is asked once
    /// when the menu is built, the same way `maintenanceOperations` is, rather than curated per
    /// engine in the metadata registry: the statement and the answer then come from one place and
    /// cannot drift apart.
    struct Context {
        /// The refs the driver answered with a statement for, resolved per name because a plugin
        /// may refuse one object and not another: Elasticsearch has no statement for an index
        /// name carrying a wildcard, which would otherwise reach the cluster as `DELETE /*`.
        let droppable: Set<DatabaseTreeTableRef>
        let truncatable: Set<DatabaseTreeTableRef>
        let isReadOnly: Bool

        /// For callers with no driver to ask, such as a window whose session has gone.
        static let unavailable = Context(droppable: [], truncatable: [], isReadOnly: true)
    }

    /// A kind whose rows the engine will not let you replace or remove in place. A view holds no
    /// rows of its own, a foreign or external table proxies rows on another server, and a system
    /// table belongs to the catalog.
    static func isReadOnlyKind(_ type: TableInfo.TableType?) -> Bool {
        switch type {
        case .view, .materializedView, .foreignTable, .systemTable, .externalTable:
            return true
        case .table, .partitionedTable, .none:
            return false
        }
    }

    static func canTruncate(_ type: TableInfo.TableType?) -> Bool {
        !isReadOnlyKind(type)
    }

    /// All or nothing over a selection, rather than truncating the eligible part of it. A command
    /// that silently acts on some of what the user selected is worse than one that declines: the
    /// rows it skipped look truncated until someone checks.
    static func canTruncate(_ targets: some Collection<DatabaseTreeTableRef>) -> Bool {
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { canTruncate($0.table.type) }
    }

    static func canTruncate(_ targets: some Collection<DatabaseTreeTableRef>, context: Context) -> Bool {
        guard !context.isReadOnly, canTruncate(targets) else { return false }
        return targets.allSatisfy { context.truncatable.contains($0) }
    }

    /// Whether Delete may be offered.
    ///
    /// All or nothing over the selection, for the reason Truncate already gives: a command that
    /// drops part of what the user selected is worse than one that declines. The menu never offers
    /// what the driver would refuse, the rule the rename path states in
    /// `PluginDriverUnsupportedOperation`.
    static func canDrop(_ targets: some Collection<DatabaseTreeTableRef>, context: Context) -> Bool {
        guard !context.isReadOnly, !targets.isEmpty else { return false }
        return targets.allSatisfy { context.droppable.contains($0) }
    }

    /// The driver's vocabulary for the same kind. Spelled out rather than taken from `rawValue` so
    /// adding a case to `TableInfo.TableType` stops compiling here instead of silently producing a
    /// kind no driver declares, which would read as "no maintenance applies".
    static func pluginKind(_ type: TableInfo.TableType?) -> PluginObjectKind {
        switch type {
        case .table, .none:     return .table
        case .partitionedTable: return .partitionedTable
        case .view:             return .view
        case .materializedView: return .materializedView
        case .foreignTable:     return .foreignTable
        case .systemTable:      return .systemTable
        case .externalTable:    return .externalTable
        }
    }

    /// The maintenance the driver offers on an object of this kind.
    ///
    /// The one answer for the sidebar's contextual menu, the menu bar's Table Maintenance submenu and
    /// the MCP tool. Offering every operation on every row is how `VACUUM` came to be offered on a
    /// view, where PostgreSQL skips it with a WARNING and still reports success, and `REINDEX` on one,
    /// where it fails outright.
    ///
    /// An operation whose statement names no object is kept whatever the row is: the row is only
    /// where it is reached from, which is how SQLite's `VACUUM` is reachable at all.
    static func maintenanceOperations(
        _ all: [PluginMaintenanceOperation],
        for type: TableInfo.TableType?
    ) -> [PluginMaintenanceOperation] {
        let kind = pluginKind(type)
        return all.filter { $0.scope.admitsObject ? $0.applies(to: kind) : true }
    }
}
