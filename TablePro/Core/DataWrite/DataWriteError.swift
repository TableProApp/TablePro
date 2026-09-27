//
//  DataWriteError.swift
//  TablePro
//

import Foundation

enum DataWriteError: LocalizedError, Equatable {
    case statementGenerationUnavailable(String)
    case statementGenerationFailed(String)
    case objectOperationUnsupported(String)
    case rowsNotIdentifiable(String, RowWriteKind)
    case changeRefused(table: String, kind: RowWriteKind?, reason: String)
    case changesNotWritable(table: String, unwritten: UnwrittenRowCounts)
    case identityNotPreservable(String)
    case tooManyRowsAffected(table: String, expected: Int, actual: Int)
    case tooManyRowsAffectedUnrecoverable(table: String, expected: Int, actual: Int)
    case tooManyRowsAffectedInSessionTransaction(table: String, expected: Int, actual: Int)
    case rowsNoLongerMatch(table: String, expected: Int, actual: Int)

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
        case .objectOperationUnsupported(let object):
            return String(
                format: String(localized: "This database has no statement for '%@'."),
                object
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
        case .changeRefused(let table, let kind, let reason):
            return String(format: Self.refusalFormat(for: kind), table, reason)
        case .changesNotWritable(let table, let unwritten):
            let lead = String(format: String(localized: "Cannot save changes to '%@'."), table)
            return ([lead] + unwritten.sentences).joined(separator: " ")
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
        case .rowsNoLongerMatch(let table, let expected, let actual):
            return String(
                format: String(
                    localized: "A statement on '%1$@' matched %2$d rows instead of %3$d, so nothing was saved."
                ),
                table, actual, expected
            )
        case .tooManyRowsAffectedUnrecoverable(let table, let expected, let actual),
             .tooManyRowsAffectedInSessionTransaction(let table, let expected, let actual):
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
        case .tooManyRowsAffectedInSessionTransaction(let table, _, _):
            return String(
                format: String(
                    localized: """
                    The extra rows are pending in the transaction already open on this connection. \
                    Roll it back to discard them. '%@' has no primary key, so identical rows cannot \
                    be told apart.
                    """
                ),
                table
            )
        case .rowsNoLongerMatch(let table, _, _):
            return String(
                format: String(
                    localized: """
                    '%@' has no primary key, so the row is found by matching every column. \
                    Another client may have changed it, or a value in it cannot be compared. \
                    Your edit is still here.
                    """
                ),
                table
            )
        case .identityNotPreservable:
            return String(localized: "Restore the row by inserting it again, then check anything that referenced its key.")
        case .rowsNotIdentifiable(_, .insert):
            return String(
                localized: "This database has no statement for a new row that sets no column. Enter a value in at least one column, or insert the row with a query."
            )
        case .changeRefused, .changesNotWritable:
            return String(
                localized: "Nothing was saved, and every change is still pending. Undo what cannot be written, or make it with a query, then save again."
            )
        default:
            return nil
        }
    }

    private static func refusalFormat(for kind: RowWriteKind?) -> String {
        switch kind {
        case .insert:
            return String(localized: "Cannot save the new row in '%1$@'. %2$@")
        case .update:
            return String(localized: "Cannot save the edited row in '%1$@'. %2$@")
        case .delete:
            return String(localized: "Cannot delete the row in '%1$@'. %2$@")
        case nil:
            return String(localized: "Cannot save changes to '%1$@'. %2$@")
        }
    }
}
