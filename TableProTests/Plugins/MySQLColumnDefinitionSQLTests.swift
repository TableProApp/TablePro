//
//  MySQLColumnDefinitionSQLTests.swift
//  TableProTests
//
//  MySQL restates a column in full for MODIFY/CHANGE COLUMN, so every attribute the
//  clause builder omits is dropped by the server. These cover the attributes that a
//  round trip has to carry through an edit to an unrelated field.
//

import TableProPluginKit
import Testing

@Suite("MySQL Column Definition SQL")
struct MySQLColumnDefinitionSQLTests {
    private func timestampColumn(
        dataType: String = "TIMESTAMP",
        defaultValue: String? = nil,
        onUpdate: String? = nil,
        comment: String? = nil
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: "updated_at",
            dataType: dataType,
            isNullable: false,
            defaultValue: defaultValue,
            comment: comment,
            onUpdate: onUpdate
        )
    }

    // MARK: - On Update

    @Test("On update renders for a timestamp column")
    func onUpdateRenders() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(defaultValue: "CURRENT_TIMESTAMP", onUpdate: "CURRENT_TIMESTAMP")
        )
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"))
    }

    @Test("On update adopts the column's fractional-second precision")
    func onUpdateDerivesPrecision() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "TIMESTAMP(6)", onUpdate: "CURRENT_TIMESTAMP")
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP(6)"))
    }

    @Test("On update precision is re-derived rather than trusted")
    func onUpdateOverridesStalePrecision() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "DATETIME(3)", onUpdate: "CURRENT_TIMESTAMP(6)")
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP(3)"))
        #expect(!sql.contains("CURRENT_TIMESTAMP(6)"))
    }

    @Test("An expression outside the whitelist is omitted, never emitted raw")
    func onUpdateRejectsUnknownExpression() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(onUpdate: "NOW()"))
        #expect(!sql.contains("ON UPDATE"))
        #expect(!sql.contains("NOW()"))
    }

    @Test("No on update attribute emits no clause")
    func onUpdateAbsent() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(defaultValue: "CURRENT_TIMESTAMP"))
        #expect(!sql.contains("ON UPDATE"))
    }

    @Test("Editing an unrelated attribute keeps the on update clause")
    func onUpdateSurvivesCommentEdit() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(
                defaultValue: "CURRENT_TIMESTAMP", onUpdate: "CURRENT_TIMESTAMP", comment: "touched"
            )
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP"))
        #expect(sql.contains("COMMENT 'touched'"))
    }

    // MARK: - Default Value

    @Test("A fractional-second default is an expression, not a quoted literal")
    func fractionalDefaultIsNotQuoted() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "TIMESTAMP(6)", defaultValue: "CURRENT_TIMESTAMP(6)")
        )
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP(6)"))
        #expect(!sql.contains("'CURRENT_TIMESTAMP"))
    }

    @Test("A bare CURRENT_TIMESTAMP default is unquoted")
    func bareDefaultIsNotQuoted() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(defaultValue: "CURRENT_TIMESTAMP"))
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP"))
        #expect(!sql.contains("'CURRENT_TIMESTAMP'"))
    }

    @Test("A quoted literal default is emitted as written")
    func quotedLiteralPassesThrough() {
        let column = PluginColumnDefinition(
            name: "status", dataType: "VARCHAR(16)", isNullable: false, defaultValue: "'it''s active'"
        )
        #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT 'it''s active'"))
    }

    @Test("An expression default is emitted as written rather than quoted")
    func expressionDefaultIsNotQuoted() {
        let column = PluginColumnDefinition(
            name: "id", dataType: "VARCHAR(36)", isNullable: false, defaultValue: "(UUID())"
        )
        let sql = mysqlColumnDefinitionSQL(column)
        #expect(sql.contains("DEFAULT (UUID())"))
        #expect(!sql.contains("'(UUID())'"))
    }

    @Test(
        "A type that cannot carry a bare default is given the parentheses the grammar needs",
        arguments: [
            (dataType: "TEXT", value: "''", expected: "DEFAULT ('')"),
            (dataType: "LONGBLOB", value: "''", expected: "DEFAULT ('')"),
            (dataType: "JSON", value: "'{}'", expected: "DEFAULT ('{}')"),
            (dataType: "GEOMETRY", value: "ST_GeomFromText('POINT(0 0)')",
             expected: "DEFAULT (ST_GeomFromText('POINT(0 0)'))"),
            (dataType: "TEXT", value: "(UUID())", expected: "DEFAULT (UUID())"),
            (dataType: "VARCHAR(16)", value: "''", expected: "DEFAULT ''")
        ]
    )
    func parenthesisedWhereRequired(dataType: String, value: String, expected: String) {
        let column = PluginColumnDefinition(
            name: "payload", dataType: dataType, isNullable: true, defaultValue: value
        )
        #expect(mysqlColumnDefinitionSQL(column).contains(expected))
    }

    // MARK: - Catalog Round Trip

    @Test(
        "A MySQL catalog default becomes the SQL that recreates it",
        arguments: [
            (value: "abc", extra: "", type: "VARCHAR(16)", expected: "'abc'"),
            (value: "", extra: "", type: "VARCHAR(16)", expected: "''"),
            (value: "it's", extra: "", type: "VARCHAR(16)", expected: "'it''s'"),
            (value: "0", extra: "", type: "INT", expected: "'0'"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "DATETIME(6)", expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "VARCHAR(32)", expected: "'CURRENT_TIMESTAMP'"),
            (value: "uuid()", extra: "DEFAULT_GENERATED", type: "VARCHAR(36)", expected: "(uuid())"),
            (value: "(curdate() + interval 1 year)", extra: "DEFAULT_GENERATED", type: "DATE",
             expected: "(curdate() + interval 1 year)")
        ]
    )
    func catalogDefaultRoundTrip(value: String, extra: String, type: String, expected: String) {
        let resolved = mysqlDefaultValueFromCatalog(value, extra: extra, dataType: type, quotesLiterals: false)
        #expect(resolved == expected)
    }

    @Test("A server that quotes its own literals has already produced the SQL")
    func quotingServerCatalogDefaultPassesThrough() {
        #expect(
            mysqlDefaultValueFromCatalog("'abc'", extra: "", dataType: "VARCHAR(16)", quotesLiterals: true) == "'abc'"
        )
        #expect(
            mysqlDefaultValueFromCatalog("uuid()", extra: "", dataType: "VARCHAR(36)", quotesLiterals: true) == "uuid()"
        )
    }

    /// MariaDB began quoting `COLUMN_DEFAULT` in 10.2.7. Before that it reads like MySQL without the
    /// `DEFAULT_GENERATED` marker, so a bare literal has to be quoted rather than passed through.
    @Test(
        "Whether the catalog quotes its literals follows the server version",
        arguments: [
            (banner: "10.6.16-MariaDB", isMariaDB: true, expected: true),
            (banner: "10.2.7-MariaDB", isMariaDB: true, expected: true),
            (banner: "10.2.6-MariaDB", isMariaDB: true, expected: false),
            (banner: "10.1.48-MariaDB", isMariaDB: true, expected: false),
            (banner: "10.0.38-MariaDB", isMariaDB: true, expected: false),
            (banner: "8.4.11", isMariaDB: false, expected: false),
            (banner: "5.7.44", isMariaDB: false, expected: false)
        ]
    )
    func catalogQuotingFollowsTheVersion(banner: String, isMariaDB: Bool, expected: Bool) {
        #expect(MySQLServerVersion.quotesColumnDefault(banner: banner, isMariaDB: isMariaDB) == expected)
    }

    @Test("An older MariaDB literal is quoted rather than passed through")
    func olderMariaDBLiteralIsQuoted() {
        #expect(
            mysqlDefaultValueFromCatalog("active", extra: "", dataType: "VARCHAR(16)", quotesLiterals: false)
                == "'active'"
        )
    }

    @Test("No default at all stays absent")
    func absentCatalogDefault() {
        #expect(mysqlDefaultValueFromCatalog(nil, extra: "", dataType: "INT", quotesLiterals: false) == nil)
        #expect(mysqlDefaultValueFromCatalog(nil, extra: "", dataType: "INT", quotesLiterals: true) == nil)
    }

    @Test("A numeric default is unquoted")
    func numericDefaultStaysUnquoted() {
        let column = PluginColumnDefinition(
            name: "qty", dataType: "INT", isNullable: false, defaultValue: "0"
        )
        #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT 0"))
    }

    // MARK: - Precision Extraction

    @Test(
        "Fractional-second precision comes from the declared type only",
        arguments: [
            (dataType: "TIMESTAMP", expected: ""),
            (dataType: "TIMESTAMP(6)", expected: "(6)"),
            (dataType: "timestamp(3)", expected: "(3)"),
            (dataType: "DATETIME", expected: ""),
            (dataType: "DATETIME(0)", expected: "(0)"),
            (dataType: "VARCHAR(255)", expected: ""),
            (dataType: "ENUM('a(1)','b')", expected: "")
        ]
    )
    func precisionExtraction(dataType: String, expected: String) {
        #expect(mysqlFractionalSecondsSuffix(forDataType: dataType) == expected)
    }

    // MARK: - Other Attributes

    @Test("Charset, collation, unsigned, and auto increment all render")
    func attributesRender() {
        let column = PluginColumnDefinition(
            name: "id",
            dataType: "BIGINT",
            isNullable: false,
            autoIncrement: true,
            unsigned: true,
            charset: "utf8mb4",
            collation: "utf8mb4_general_ci"
        )

        let sql = mysqlColumnDefinitionSQL(column)
        #expect(sql.contains("`id` BIGINT"))
        #expect(sql.contains("UNSIGNED"))
        #expect(sql.contains("CHARACTER SET utf8mb4"))
        #expect(sql.contains("COLLATE utf8mb4_general_ci"))
        #expect(sql.contains("NOT NULL"))
        #expect(sql.contains("AUTO_INCREMENT"))
    }

    @Test("A backtick in a column name is escaped")
    func backtickEscaping() {
        let column = PluginColumnDefinition(name: "col`name", dataType: "INT")
        #expect(mysqlColumnDefinitionSQL(column).contains("`col``name`"))
    }
}
