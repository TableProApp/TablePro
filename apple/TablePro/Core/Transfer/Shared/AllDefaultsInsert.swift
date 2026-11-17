import Foundation
import TableProPluginKit

// A row whose every column the server fills in. Returning nothing dropped such a row from a save that still reported
// success.
nonisolated enum AllDefaultsInsert {
    // Nil where the engine has no such spelling, or needs a column to name and the table has none left.
    static func sql(into qualifiedTable: String, databaseTypeId: String, firstWritableColumn: String?) -> String? {
        switch SqlDialect.from(databaseTypeId: databaseTypeId) {
        case .postgres, .sqlite:
            return "INSERT INTO \(qualifiedTable) DEFAULT VALUES"
        case .mysql:
            return "INSERT INTO \(qualifiedTable) () VALUES ()"
        default:
            break
        }
        switch databaseTypeId {
        case "SQL Server":
            return "INSERT INTO \(qualifiedTable) DEFAULT VALUES"
        case "Databend", "Oracle":
            guard let firstWritableColumn else { return nil }
            return "INSERT INTO \(qualifiedTable) (\(firstWritableColumn)) VALUES (DEFAULT)"
        default:
            return nil
        }
    }
}
