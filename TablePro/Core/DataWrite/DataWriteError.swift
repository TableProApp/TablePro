//
//  DataWriteError.swift
//  TablePro
//

import Foundation

enum DataWriteError: LocalizedError, Equatable {
    case statementGenerationUnavailable(String)
    case statementGenerationFailed(String)
    case rowsNotIdentifiable(String, RowWriteKind)
    case identityNotPreservable(String)
    case tooManyRowsAffected(table: String, expected: Int, actual: Int)
    case tooManyRowsAffectedUnrecoverable(table: String, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .statementGenerationUnavailable(let engine):
            return String(
                format: String(localized: "Cannot generate statements for %@: the driver is not loaded."),
                engine
            )
        case .statementGenerationFailed(let table):
            return String(
                format: String(localized: "Could not generate SQL for '%@'."),
                table
            )
        case .rowsNotIdentifiable(let table, let kind):
            switch kind {
            case .update:
                return String(
                    format: String(localized: "Cannot save changes to '%@'. Some rows could not be identified."),
                    table
                )
            case .delete:
                return String(
                    format: String(localized: "Cannot delete rows in '%@'. Some rows could not be identified."),
                    table
                )
            case .insert:
                return String(
                    format: String(localized: "Cannot insert rows into '%@'."),
                    table
                )
            }
        case .identityNotPreservable(let engine):
            return String(
                format: String(localized: "%@ cannot restore a deleted row with its original key."),
                engine
            )
        case .tooManyRowsAffected(let table, let expected, let actual):
            return String(
                format: String(
                    localized: "A statement on '%1$@' matched %2$d rows instead of %3$d, so nothing was saved."
                ),
                table, actual, expected
            )
        case .tooManyRowsAffectedUnrecoverable(let table, let expected, let actual):
            return String(
                format: String(
                    localized: "A statement on '%1$@' matched %2$d rows instead of %3$d."
                ),
                table, actual, expected
            )
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .tooManyRowsAffected(let table, _, _):
            return String(
                format: String(
                    localized: "'%@' has no primary key, so identical rows cannot be told apart. Add a primary key, or edit the rows with a query."
                ),
                table
            )
        case .tooManyRowsAffectedUnrecoverable(let table, _, _):
            return String(
                format: String(
                    localized: "This engine has no transactions, so the extra rows were already written. '%@' has no primary key, so identical rows cannot be told apart."
                ),
                table
            )
        case .identityNotPreservable:
            return String(localized: "Restore the row by inserting it again, then check anything that referenced its key.")
        default:
            return nil
        }
    }
}
