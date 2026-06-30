import AppIntents
import Foundation

enum IntentDataError: Error, CustomLocalizedStringResourceConvertible {
    case connectionNotFound
    case unsupportedDatabaseType(String)
    case connectionFailed(String)
    case readOnly(String)
    case noColumns(String)
    case noInsertableValues(String)
    case unknownColumns([String], String)
    case emptyPayload
    case expectedSingleRow
    case malformedPayload(String)
    case tooManyRows(Int)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .connectionNotFound:
            return "That connection no longer exists in TablePro."
        case .unsupportedDatabaseType(let type):
            return "\(type) connections do not support adding rows from Shortcuts."
        case .connectionFailed(let message):
            return "Could not connect to the database: \(message)"
        case .readOnly(let name):
            return "\(name) is read-only, so rows cannot be added."
        case .noColumns(let table):
            return "Could not read the columns of \(table)."
        case .noInsertableValues(let table):
            return "The data has no values to insert into \(table)."
        case .unknownColumns(let columns, let table):
            return "\(table) has no column named \(columns.joined(separator: ", "))."
        case .emptyPayload:
            return "No data was provided to add."
        case .expectedSingleRow:
            return "Add Row to Table expects one row. Use Add Rows to Table for multiple rows."
        case .malformedPayload(let message):
            return "The data could not be read: \(message)"
        case .tooManyRows(let limit):
            return "Too many rows. Add up to \(limit) rows at a time."
        }
    }
}
