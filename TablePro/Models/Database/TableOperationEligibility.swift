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
}
