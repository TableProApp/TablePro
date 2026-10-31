//
//  TableOptionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TableOptionsTests {
    private static let catalog = TableOptionsCatalog(
        characterSets: [
            TableCharacterSet(
                name: "latin1", defaultCollation: "latin1_swedish_ci",
                collations: ["latin1_bin", "latin1_swedish_ci"], description: nil
            ),
            TableCharacterSet(
                name: "utf8mb4", defaultCollation: "utf8mb4_0900_ai_ci",
                collations: ["utf8mb4_0900_ai_ci", "utf8mb4_bin", "utf8mb4_unicode_ci"], description: nil
            )
        ],
        engines: ["InnoDB"],
        defaultEngine: "InnoDB"
    )

    private func latinName() -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = "name"
        column.dataType = "VARCHAR(32)"
        column.setCharacterSet("latin1", collation: "latin1_swedish_ci")
        return column
    }

    @Test(
        "Character and text types take a character set, whatever the spelling",
        arguments: [
            "VARCHAR(32)", "varchar (64)", "CHAR(10)", "character(10)", "character varying(64)", "char varying(8)",
            "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "LONG VARCHAR", "ENUM('a','b')", "ENUM ('a')",
            "SET('x','y')", "TEXT BINARY", "VARCHAR(10) BINARY"
        ]
    )
    func textTypesTakeACharacterSet(_ dataType: String) {
        #expect(ColumnTextType.takesCharacterSet(dataType))
    }

    @Test(
        "National, binary, JSON, numeric and temporal types take none",
        arguments: [
            "NCHAR(10)", "NVARCHAR(10)", "NATIONAL VARCHAR(10)", "NATIONAL CHARACTER VARYING(10)", "BINARY(16)",
            "VARBINARY(32)", "BLOB", "LONGBLOB", "LONG VARBINARY", "CHAR BYTE", "JSON", "INT", "BIGINT UNSIGNED",
            "DECIMAL(10,2)", "DATETIME(6)", "TIMESTAMP", ""
        ]
    )
    func otherTypesTakeNone(_ dataType: String) {
        #expect(!ColumnTextType.takesCharacterSet(dataType))
    }

    @Test("The counter's range follows the integer type and its sign")
    func autoIncrementMaximumFollowsTheType() {
        #expect(AutoIncrementRange.maximum(forColumnType: "TINYINT") == 127)
        #expect(AutoIncrementRange.maximum(forColumnType: "TINYINT UNSIGNED") == 255)
        #expect(AutoIncrementRange.maximum(forColumnType: "smallint(6)") == 32_767)
        #expect(AutoIncrementRange.maximum(forColumnType: "MEDIUMINT UNSIGNED") == 16_777_215)
        #expect(AutoIncrementRange.maximum(forColumnType: "INT(11)") == 2_147_483_647)
        #expect(AutoIncrementRange.maximum(forColumnType: "int unsigned") == 4_294_967_295)
        #expect(AutoIncrementRange.maximum(forColumnType: "BIGINT") == 9_223_372_036_854_775_807)
        #expect(AutoIncrementRange.maximum(forColumnType: "BIGINT UNSIGNED") == UInt64.max)
        #expect(AutoIncrementRange.maximum(forColumnType: "SERIAL") == UInt64.max)
        #expect(AutoIncrementRange.maximum(forColumnType: "INT", unsigned: true) == 4_294_967_295)
        #expect(AutoIncrementRange.maximum(forColumnType: "DOUBLE") == nil)
        #expect(AutoIncrementRange.maximum(forColumnType: "VARCHAR(10)") == nil)
    }

    @Test("The catalog finds a character set, its collations and the set a collation belongs to")
    func catalogLookups() {
        #expect(Self.catalog.defaultCollation(for: "UTF8MB4") == "utf8mb4_0900_ai_ci")
        #expect(Self.catalog.collations(for: "latin1") == ["latin1_bin", "latin1_swedish_ci"])
        #expect(Self.catalog.collations(for: "koi8r").isEmpty)
        #expect(Self.catalog.characterSet(owning: "utf8mb4_bin")?.name == "utf8mb4")
        #expect(Self.catalog.characterSet(owning: "cp1251_bin") == nil)
    }

    @Test("A draft stages nothing until it differs, and a convert to the current set is a change")
    func draftChanges() {
        let loaded = TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 4)
        var draft = TableOptionsDraft(original: loaded)
        #expect(!draft.hasChanges)

        draft.current?.convertsColumns = true
        #expect(draft.characterSetChange == .modifyTableCharacterSet(
            old: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci"),
            new: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", convertsColumns: true)
        ))
        #expect(draft.autoIncrementChange == nil)
    }

    @Test("A draft over a failed read stages nothing")
    func draftWithoutBaselineStagesNothing() {
        var draft = TableOptionsDraft(original: nil)
        draft.current = TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_bin", autoIncrement: 10)
        #expect(!draft.hasChanges)
    }

    @Test("A type that takes no character set clears the column's pair in the same write")
    func nonTextTypeClearsThePair() {
        var column = latinName()

        column.setDataType("INT")

        #expect(column.dataType == "INT")
        #expect(column.charset == nil)
        #expect(column.collation == nil)
        #expect(column.toPlugin().charset == nil)
    }

    @Test("A text type keeps the column's pair")
    func textTypeKeepsThePair() {
        var column = latinName()

        column.setDataType("TEXT")

        #expect(column.charset == "latin1")
        #expect(column.collation == "latin1_swedish_ci")
    }

    @Test("A grid type edit on an engine with character sets clears the pair")
    func gridTypeEditClearsThePair() {
        var column = latinName()

        StructureEditingSupport.updateColumn(&column, at: 0, with: "INT", orderedFields: [.type, .charset, .collation])

        #expect(column.charset == nil)
        #expect(column.collation == nil)
    }

    @Test("A grid type edit on an engine without character sets keeps the collation for its driver")
    func gridTypeEditWithoutCharsetFieldKeepsCollation() {
        var column = latinName()
        column.setCharacterSet(nil, collation: "C")

        StructureEditingSupport.updateColumn(&column, at: 1, with: "integer", orderedFields: [.name, .type])

        #expect(column.dataType == "integer")
        #expect(column.collation == "C")
    }

    @Test("Picking a character set starts it on that set's default collation")
    func characterSetPickTakesTheDefaultCollation() {
        var column = latinName()

        StructureEditingSupport.updateColumn(
            &column, at: 0, with: "utf8mb4", orderedFields: [.charset], catalog: Self.catalog
        )

        #expect(column.charset == "utf8mb4")
        #expect(column.collation == "utf8mb4_0900_ai_ci")
    }

    @Test("Picking the character set the column has keeps its collation")
    func sameCharacterSetKeepsTheCollation() {
        var column = latinName()
        column.setCharacterSet("latin1", collation: "latin1_bin")

        StructureEditingSupport.updateColumn(
            &column, at: 0, with: "latin1", orderedFields: [.charset], catalog: Self.catalog
        )

        #expect(column.collation == "latin1_bin")
    }

    @Test("A character set picked without a catalog leaves the collation to the server")
    func characterSetWithoutCatalogClearsCollation() {
        var column = latinName()

        StructureEditingSupport.updateColumn(&column, at: 0, with: "utf8mb4", orderedFields: [.charset])

        #expect(column.charset == "utf8mb4")
        #expect(column.collation == nil)
    }

    @Test("A collation from another character set moves the character set with it")
    func collationCarriesItsCharacterSet() {
        var column = latinName()

        StructureEditingSupport.updateColumn(
            &column, at: 0, with: "utf8mb4_bin", orderedFields: [.collation], catalog: Self.catalog
        )

        #expect(column.charset == "utf8mb4")
        #expect(column.collation == "utf8mb4_bin")
    }

    @Test("A column carries its CHECK clause to the plugin and back")
    func columnCheckRoundTrips() {
        let info = ColumnInfo(
            name: "n", dataType: "INT", isNullable: true, isPrimaryKey: false, columnCheck: "`n` > 0"
        )
        let column = EditableColumnDefinition.from(info)

        #expect(column.toPlugin().columnCheck == "`n` > 0")
        #expect(column.toColumnInfo().columnCheck == "`n` > 0")
    }

    @Test("A column copied to the clipboard leaves its CHECK clause behind")
    func columnCheckIsNotEncoded() throws {
        var column = latinName()
        column.columnCheck = "`name` <> ''"

        let data = try JSONEncoder().encode(column)
        let decoded = try JSONDecoder().decode(EditableColumnDefinition.self, from: data)

        #expect(decoded.columnCheck == nil)
    }
}
