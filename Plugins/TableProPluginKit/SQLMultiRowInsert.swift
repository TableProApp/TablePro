//
//  SQLMultiRowInsert.swift
//  TableProPluginKit
//

import Foundation

/// How many rows one `INSERT ... VALUES` may carry on an engine, as a matter of syntax rather than size.
///
/// This is not a tuning knob and it is not a packet limit. It is the point at which an engine stops
/// parsing the statement at all:
///
/// - SQL Server: "When used as the `VALUES` clause of an `INSERT ... VALUES` statement, there is a
///   limit of 1,000 rows. Error 10738 is returned if the number of rows exceeds the maximum."
/// - Oracle: a single-table `INSERT ... VALUES` takes one row. Multiple rows need `INSERT ALL` or
///   `INSERT ... SELECT`, neither of which this app writes, so anything above one row is unparseable.
///
/// `SqlDialect` cannot answer this, because it has four cases and both engines land in `.generic`
/// alongside engines that take multi-row `VALUES` perfectly well. So the question is asked of the
/// database type id, and an id this does not name is unlimited: an engine is only listed once its
/// ceiling is documented, never on a guess.
public enum SQLMultiRowInsert {
    /// `Int.max` means "no syntax ceiling", so a caller can `min` this against its own row cap without
    /// branching.
    public static func maximumRowsPerStatement(forDatabaseTypeId databaseTypeId: String) -> Int {
        switch databaseTypeId {
        case "Oracle": return 1
        case "SQL Server": return 1_000
        default: return .max
        }
    }
}
