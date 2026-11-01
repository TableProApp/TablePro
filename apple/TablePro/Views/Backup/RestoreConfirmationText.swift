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
                    The dump is replayed into this database, and the change cannot be undone. A backup \
                    TablePro wrote overwrites each object it names. The restore stops at the first \
                    error and keeps what ran before it.
                    """)
        case .addsToExistingObjects:
            return String(
                localized: """
                    The dump is replayed into this database, and the change cannot be undone. Objects \
                    that already exist are kept, not replaced, and the dump's data is added to them. \
                    The restore carries on past errors, such as a key that already exists.
                    """)
        case .stopsAtFirstError:
            return String(
                localized: """
                    The dump is replayed into this database, and the change cannot be undone. The \
                    restore stops at the first error, such as a key or object that already exists. If \
                    the dump is one transaction, as every backup TablePro writes is, none of it is kept. \
                    Otherwise what ran before the error stays.
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
