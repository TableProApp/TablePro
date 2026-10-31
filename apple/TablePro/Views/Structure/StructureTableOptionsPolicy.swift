//
//  StructureTableOptionsPolicy.swift
//  TablePro
//

import Foundation

internal enum StructureTableOptionsPolicy {
    internal struct Editability: Equatable {
        internal var isEditable: Bool
        internal var unavailableReason: String?
    }

    // Without a baseline nothing can be staged: the read is still running or failed, and the tab says which.
    internal static func resolve(hasBaseline: Bool, isReadOnly: Bool, isSaving: Bool) -> Editability {
        if isSaving {
            return Editability(isEditable: false, unavailableReason: StructureFooterPolicy.savingReason)
        }
        guard hasBaseline else {
            return Editability(isEditable: false, unavailableReason: nil)
        }
        guard !isReadOnly else {
            return Editability(
                isEditable: false,
                unavailableReason: String(
                    localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
                )
            )
        }
        return Editability(isEditable: true, unavailableReason: nil)
    }
}
