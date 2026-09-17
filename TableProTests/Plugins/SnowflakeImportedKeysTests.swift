//
//  SnowflakeImportedKeysTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// `SHOW IMPORTED KEYS` reports `pk_database_name` beside `pk_schema_name`, and the driver read only
/// the second, so a key pointing into another database resolved to the current one's same-named
/// table. Snowflake names objects in three parts, so the database is the half that was missing.
@Suite("Snowflake imported keys")
struct SnowflakeImportedKeysTests {
    @Test("A key into another database reports that database")
    func crossDatabaseKeyReportsItsDatabase() {
        #expect(
            SnowflakeSchemaQueries.referencedDatabase(reported: "RAW", local: "ANALYTICS") == "RAW"
        )
    }

    /// A same-database key must resolve exactly as it did before the fix, or every existing key on
    /// every Snowflake account moves.
    @Test("A key into the current database reports nothing")
    func sameDatabaseKeyReportsNothing() {
        #expect(
            SnowflakeSchemaQueries.referencedDatabase(reported: "ANALYTICS", local: "ANALYTICS") == nil
        )
    }

    /// Snowflake folds an unquoted identifier to upper case and answers in its own spelling, so the
    /// two sides can differ in case for one database.
    @Test("Case alone does not make it another database")
    func caseAloneIsNotAnotherDatabase() {
        #expect(
            SnowflakeSchemaQueries.referencedDatabase(reported: "ANALYTICS", local: "analytics") == nil
        )
    }

    /// An older Snowflake, or a result read through a path that does not carry the column.
    @Test("A result with no database column reports nothing", arguments: [String?.none, ""])
    func missingDatabaseColumnReportsNothing(reported: String?) {
        #expect(SnowflakeSchemaQueries.referencedDatabase(reported: reported, local: "ANALYTICS") == nil)
    }

    @Test("With no current database the reported one is taken at its word")
    func withoutALocalDatabaseTheReportedOneStands() {
        #expect(SnowflakeSchemaQueries.referencedDatabase(reported: "RAW", local: nil) == "RAW")
        #expect(SnowflakeSchemaQueries.referencedDatabase(reported: "RAW", local: "") == "RAW")
    }
}
