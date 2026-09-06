//
//  TableOperationEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which objects a table operation may be aimed at.
///
/// The sidebar's contextual menu and the menu bar both offer Truncate, and they used to decide
/// eligibility separately: the sidebar hid the item for a view, while the menu bar's validator
/// asked only whether anything was selected. So selecting a view and using the menu bar staged a
/// `TRUNCATE` against it that the server then refused, failing the whole save.
///
/// It lives beside the models rather than beside the sidebar because the menu-bar validator in
/// `Core/` has to reach it too, and a `Views/` file is the wrong dependency for that.
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
