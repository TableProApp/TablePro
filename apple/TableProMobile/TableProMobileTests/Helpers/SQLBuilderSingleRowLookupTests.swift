import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

struct SQLBuilderSingleRowLookupTests {
    private func driver(backslashEscaping: Bool = false) -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.usesBackslashEscaping = backslashEscaping
        return driver
    }

    private func lookup(
        _ key: [(column: String, value: String)],
        schema: String? = nil,
        columns: [ColumnInfo] = [],
        type: DatabaseType = .postgresql,
        backslashEscaping: Bool = false
    ) -> String {
        SQLBuilder.buildSingleRowLookup(
            table: "parent", schema: schema, key: key, columns: columns,
            type: type, driver: driver(backslashEscaping: backslashEscaping)
        )
    }

    @Test("A plain value reads as one statement against the named column")
    func plainValue() {
        #expect(lookup([("code", "abc")]) == "SELECT * FROM \"parent\" WHERE \"code\" = 'abc' LIMIT 1 OFFSET 0")
    }

    @Test("A composite key matches every pair, so another tenant's row cannot answer")
    func compositeKeyMatchesEveryPair() {
        #expect(
            lookup([("tenant_id", "2"), ("id", "5")])
                == "SELECT * FROM \"parent\" WHERE \"tenant_id\" = '2' AND \"id\" = '5' LIMIT 1 OFFSET 0"
        )
    }

    @Test("Every pair of a composite key goes through the driver's escaper")
    func compositeKeyEscapesEveryValue() {
        let sql = lookup([("a", "x\\"), ("b", "O'Brien")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("WHERE `a` = 'x\\\\' AND `b` = 'O''Brien'"))
    }

    @Test("An empty key matches no row rather than any row")
    func emptyKeyMatchesNothing() {
        #expect(lookup([]) == "SELECT * FROM \"parent\" WHERE 1 = 0 LIMIT 1 OFFSET 0")
    }

    @Test("The schema is named, so the lookup cannot land on another schema's table")
    func schemaIsQualified() {
        #expect(
            lookup([("code", "abc")], schema: "sales", type: .mssql)
                .hasPrefix("SELECT * FROM [sales].[parent] WHERE [code] = N'abc'")
        )
    }

    // SQL Server and Oracle reject `LIMIT`, and the failure reads exactly like a key with no matching row.
    @Test("An OFFSET/FETCH engine gets its own clause")
    func offsetFetchEngines() {
        for type in [DatabaseType.mssql, .oracle] {
            let sql = lookup([("code", "abc")], type: type)
            #expect(sql.contains("OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY"))
            #expect(!sql.contains("LIMIT"))
        }
    }

    @Test("A quote in the value is escaped rather than closing the literal")
    func quoteIsEscaped() {
        #expect(lookup([("code", "O'Brien")]).contains("= 'O''Brien'"))
    }

    // MySQL reads `\'` as an escaped quote, so doubling the quote alone ends the literal at the value's backslash.
    @Test("A backslash before a quote cannot break out of the literal")
    func backslashCannotBreakOut() {
        let sql = lookup([("code", "a\\' OR 1=1 -- ")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("= 'a\\\\'' OR 1=1 -- '"))
        #expect(!sql.contains("'a\\'' OR"))
    }

    @Test("A trailing backslash leaves the literal closed")
    func trailingBackslashIsEscaped() {
        let sql = lookup([("code", "C:\\")], type: .mysql, backslashEscaping: true)
        #expect(sql.contains("= 'C:\\\\'"))
    }

    @Test("Every escaped value goes through the driver, never a hand-written rule")
    func escapingFollowsTheDriver() {
        let ansi = lookup([("code", "a\\b")])
        let backslash = lookup([("code", "a\\b")], type: .mysql, backslashEscaping: true)
        #expect(ansi.contains("= 'a\\b'"))
        #expect(backslash.contains("= 'a\\\\b'"))
    }

    // MySQL 8.4 and MariaDB 13 find no row for `bit_col = '5'`; the grid shows a BIT as its decimal value.
    @Test("A MySQL BIT key compares as the number the grid shows")
    func mysqlBitKeyIsBare() {
        let columns = [ColumnInfo(name: "flags", typeName: "bit(8)")]
        #expect(lookup([("flags", "5")], columns: columns, type: .mysql).contains("WHERE `flags` = 5 "))
    }

    // PostgreSQL resolves a quoted literal to the column's type, and has no `bit = integer` or `boolean = integer`.
    @Test("PostgreSQL bit, boolean and real keys stay quoted", arguments: ["bit(3)", "boolean", "real"])
    func postgresNonIntegerKeysStayQuoted(typeName: String) {
        let columns = [ColumnInfo(name: "k", typeName: typeName)]
        #expect(lookup([("k", "1")], columns: columns).contains("WHERE \"k\" = '1' "))
    }

    @Test("An integer key the columns name compares bare")
    func integerKeyIsBare() {
        let columns = [ColumnInfo(name: "id", typeName: "integer")]
        #expect(lookup([("id", "5")], columns: columns).contains("WHERE \"id\" = 5 "))
    }

    @Test("A key column the caller could not read stays quoted off SQLite")
    func unreadKeyColumnStaysQuoted() {
        #expect(lookup([("id", "5")], type: .mysql).contains("WHERE `id` = '5' "))
    }

    // SQLite keeps integer 5 and text '5' apart in a column with no affinity, and the grid shows both as 5.
    @Test("A SQLite key with no affinity matches the number either way it was stored", arguments: ["", "BLOB", "ANY"])
    func sqliteUntypedKeyMatchesEitherStorageClass(typeName: String) {
        let columns = [ColumnInfo(name: "id", typeName: typeName)]
        #expect(lookup([("id", "5")], columns: columns, type: .sqlite)
            .contains("WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5' "))
        #expect(lookup([("id", "-5")], type: .sqlite).contains("WHERE \"id\" IN (-5, '-5') AND CAST(\"id\" AS TEXT) = '-5' "))
        #expect(lookup([("id", "2.5")], type: .sqlite).contains("WHERE \"id\" IN (2.5, '2.5') AND CAST(\"id\" AS TEXT) = '2.5' "))
    }

    @Test("A SQLite value that is not how SQLite prints a number stays quoted", arguments: ["05", "+5", "5.50", "1e3", "abc", "-0"])
    func sqliteNonCanonicalNumberStaysQuoted(value: String) {
        #expect(lookup([("id", value)], type: .sqlite).contains("WHERE \"id\" = '\(value)' "))
    }

    @Test("A typed SQLite key keeps its literal")
    func sqliteTypedKey() {
        let columns = [ColumnInfo(name: "id", typeName: "INTEGER"), ColumnInfo(name: "code", typeName: "TEXT")]
        #expect(lookup([("id", "5"), ("code", "5")], columns: columns, type: .sqlite)
            .contains("WHERE \"id\" = 5 AND \"code\" = '5' "))
    }

    @Test("Update and delete identify the row with the same literal")
    func updateAndDeleteShareTheRule() {
        let columns = [ColumnInfo(name: "id", typeName: "")]
        let key = [(column: "id", value: "5")]
        #expect(SQLBuilder.buildDelete(
            table: "t", schema: nil, type: .sqlite, driver: driver(), primaryKeys: key, columns: columns
        ) == "DELETE FROM \"t\" WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5' AND (SELECT COUNT(*) FROM \"t\" WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5') = 1")
        #expect(SQLBuilder.buildUpdate(
            table: "t", schema: nil, type: .sqlite, driver: driver(),
            changes: [(column: "name", value: "x")], primaryKeys: key, columns: columns
        ) == "UPDATE \"t\" SET \"name\" = 'x' WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5' AND (SELECT COUNT(*) FROM \"t\" WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5') = 1")
    }

    @Test("Only a key matched both ways can name two rows")
    func onlyEitherWayKeysCanNameTwoRows() {
        let untyped = [ColumnInfo(name: "id", typeName: "")]
        #expect(SQLBuilder.keyMatchesEitherWay([("id", "5")], columns: untyped, type: .sqlite))
        #expect(!SQLBuilder.keyMatchesEitherWay([("id", "abc")], columns: untyped, type: .sqlite))
        #expect(!SQLBuilder.keyMatchesEitherWay([("id", "5")], columns: [ColumnInfo(name: "id", typeName: "INTEGER")], type: .sqlite))
        #expect(!SQLBuilder.keyMatchesEitherWay([("id", "5")], columns: [], type: .postgresql))
        #expect(SQLBuilder.buildKeyMatchCount(
            table: "t", schema: nil, key: [("id", "5")], columns: untyped, type: .sqlite, driver: driver()
        ) == "SELECT COUNT(*) FROM \"t\" WHERE \"id\" IN (5, '5') AND CAST(\"id\" AS TEXT) = '5'")
        #expect(SQLBuilder.buildDelete(
            table: "t", schema: nil, type: .postgresql, driver: driver(), primaryKeys: [("id", "5")], columns: []
        ) == "DELETE FROM \"t\" WHERE \"id\" = '5'")
    }
    @Test("SQL Server inserts and row edits keep exact text keys", arguments: ["\n", "\r\n", "\r"])
    func sqlServerWrites(_ newline: String) {
        let value = "日本\\" + newline
        let body = "日本\\\\" + newline + (newline == "\r" ? "" : newline)
        let literal = "N'" + body + "'"
        let connection = DatabaseConnection(name: "test", type: .mssql)
        let sqlDriver = MSSQLDriver(connection: connection, password: nil)
        #expect(sqlDriver.escapeStringLiteral(value) == body)
        let delete = SQLBuilder.buildDelete(
            table: "t", schema: "dbo", type: .mssql, driver: sqlDriver,
            primaryKeys: [("k", value)], columns: []
        )
        #expect(delete == "DELETE FROM [dbo].[t] WHERE [k] = " + literal)
        let update = SQLBuilder.buildUpdate(
            table: "t", schema: "dbo", type: .mssql, driver: sqlDriver,
            changes: [("v", value)], primaryKeys: [("k", value)], columns: []
        )
        #expect(update == "UPDATE [dbo].[t] SET [v] = " + literal + " WHERE [k] = " + literal)
        #expect(SQLBuilder.buildInsert(table: "t", schema: nil, type: .mssql, driver: sqlDriver,
            columns: ["k"], values: [value]) == "INSERT INTO [t] ([k]) VALUES (" + literal + ")")
    }

    // Under a SQL collation a varchar key holds both `Wessels` and `Weßels`, which compare equal against N'…' text.
    @Test("A SQL Server varchar key also matches its exact stored text")
    func sqlServerNarrowKeyMatchesExactly() {
        let sqlDriver = MSSQLDriver(connection: DatabaseConnection(name: "test", type: .mssql), password: nil)
        let exact = "[k] = N'Weßels' AND CAST([k] AS NVARCHAR(MAX)) COLLATE Latin1_General_100_BIN2 = N'Weßels'"
        let narrow = [ColumnInfo(name: "k", typeName: "varchar(20)")]
        #expect(SQLBuilder.buildDelete(
            table: "t", schema: "dbo", type: .mssql, driver: sqlDriver, primaryKeys: [("k", "Weßels")], columns: narrow
        ) == "DELETE FROM [dbo].[t] WHERE " + exact)
        #expect(SQLBuilder.buildUpdate(
            table: "t", schema: "dbo", type: .mssql, driver: sqlDriver,
            changes: [("v", "x")], primaryKeys: [("k", "Weßels")], columns: narrow
        ) == "UPDATE [dbo].[t] SET [v] = N'x' WHERE " + exact)
        #expect(SQLBuilder.keyPredicate([("k", "Weßels")], columns: narrow, type: .mssql, driver: sqlDriver) == exact)
        let unicode = [ColumnInfo(name: "k", typeName: "nvarchar(20)")]
        #expect(SQLBuilder.buildDelete(
            table: "t", schema: "dbo", type: .mssql, driver: sqlDriver, primaryKeys: [("k", "Weßels")], columns: unicode
        ) == "DELETE FROM [dbo].[t] WHERE [k] = N'Weßels'")
    }

    // A foreign key's `abc` refers to a parent `ABC` under a case-insensitive collation, so the lookup matches by the
    // column's rules and only prefers the parent holding the exact text.
    @Test("A SQL Server foreign key lookup keeps the collation match and prefers the exact text")
    func sqlServerLookupPrefersExactText() {
        let narrow = [ColumnInfo(name: "k", typeName: "varchar(20)")]
        #expect(lookup([("k", "abc")], columns: narrow, type: .mssql)
            == "SELECT * FROM [parent] WHERE [k] = N'abc' ORDER BY CASE WHEN CAST([k] AS NVARCHAR(MAX)) "
            + "COLLATE Latin1_General_100_BIN2 = N'abc' THEN 0 ELSE 1 END OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
        #expect(lookup([("k", "abc")], columns: [ColumnInfo(name: "k", typeName: "nvarchar(20)")], type: .mssql)
            == "SELECT * FROM [parent] WHERE [k] = N'abc' ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
    }
}

