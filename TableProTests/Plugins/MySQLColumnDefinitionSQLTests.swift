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

    @Test("A non-expression default is still quoted and escaped")
    func plainDefaultStaysQuoted() {
        let column = PluginColumnDefinition(
            name: "status", dataType: "VARCHAR(16)", isNullable: false, defaultValue: "it's active"
        )
        #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT 'it''s active'"))
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
