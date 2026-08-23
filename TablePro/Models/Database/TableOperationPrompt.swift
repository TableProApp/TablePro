//
//  TableOperationPrompt.swift
//  TablePro
//

import Foundation

internal struct TableOperationPrompt: Equatable {
    internal let operationType: TableOperationType
    internal let tableName: String
    internal let tableCount: Int
    internal let cascadeSupported: Bool
    internal let foreignKeyDisableSupported: Bool

    internal var messageText: String {
        switch operationType {
        case .drop:
            return tableCount > 1
                ? String(format: String(localized: "Drop %d tables"), tableCount)
                : String(format: String(localized: "Drop table '%@'"), tableName)
        case .truncate:
            return tableCount > 1
                ? String(format: String(localized: "Truncate %d tables"), tableCount)
                : String(format: String(localized: "Truncate table '%@'"), tableName)
        }
    }

    internal var informativeText: String {
        guard tableCount > 1 else { return "" }
        return String(localized: "Same options will be applied to all selected tables.")
    }

    internal var confirmButtonTitle: String {
        switch operationType {
        case .drop:
            return String(localized: "Drop")
        case .truncate:
            return String(localized: "Truncate")
        }
    }

    internal var cancelButtonTitle: String {
        String(localized: "Cancel")
    }

    internal var ignoreForeignKeysTitle: String {
        String(localized: "Ignore foreign key checks")
    }

    internal var isIgnoreForeignKeysEnabled: Bool {
        foreignKeyDisableSupported
    }

    internal var ignoreForeignKeysDescription: String? {
        guard !foreignKeyDisableSupported else { return nil }
        return cascadeSupported
            ? String(localized: "Not supported for this database. Use CASCADE instead.")
            : String(localized: "Not supported for this database.")
    }

    internal var cascadeTitle: String {
        String(localized: "Cascade")
    }

    internal var isCascadeEnabled: Bool {
        cascadeSupported
    }

    internal var cascadeDescription: String {
        switch operationType {
        case .drop:
            return String(localized: "Drop all tables that depend on this table")
        case .truncate:
            guard cascadeSupported else {
                return String(localized: "Not supported for TRUNCATE with this database")
            }
            return String(localized: "Truncate all tables linked by foreign keys")
        }
    }

    internal func options(ignoreForeignKeys: Bool, cascade: Bool) -> TableOperationOptions {
        TableOperationOptions(
            ignoreForeignKeys: ignoreForeignKeys && isIgnoreForeignKeysEnabled,
            cascade: cascade && isCascadeEnabled
        )
    }
}
