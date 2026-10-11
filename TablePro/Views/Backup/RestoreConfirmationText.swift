//
//  RestoreConfirmationText.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RestoreConfirmationText {
    static func message(for type: DatabaseType, formatId: String? = nil) -> String? {
        NativeDumpRegistry.descriptor(for: type, formatId: formatId).map { message(for: $0.restoreSemantics) }
    }

    static func message(for semantics: NativeDumpDescriptor.RestoreSemantics) -> String {
        switch semantics {
        case .replacesObjects:
            return String(
                localized: """
                    The dump is replayed into this database. Objects it names are overwritten and \
                    the change cannot be undone.
                    """)
        case .addsToExistingObjects:
            return String(
                localized: """
                    The dump is replayed into this database. Objects that already exist are kept, \
                    not replaced, and the dump's data is added to them. The change cannot be undone.
                    """)
        case .stopsAtExistingObjects:
            return String(
                localized: """
                    The dump is copied into this database, and the change cannot be undone. If an \
                    object it holds already exists, the restore stops before copying anything.
                    """)
        case .requiresEmptyDatabase:
            return String(
                localized: """
                    The dump is imported into this database, and the change cannot be undone. The \
                    import needs an empty database and stops if this one already holds objects.
                    """)
        }
    }
}
