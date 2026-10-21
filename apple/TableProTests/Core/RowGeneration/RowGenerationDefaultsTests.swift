//
//  RowGenerationDefaultsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct RowGenerationDefaultsTests {
    private static func text(_ name: String, maxLength: Int? = nil) -> RowGenerationColumn {
        RowGenerationColumn(name: name, typeName: "varchar", valueClass: .text(maxLength: maxLength))
    }

    @Test("A text column's generator follows its name", arguments: [
        ("email", RowGeneratorKind.email),
        ("customerEmail", .email),
        ("first_name", .firstName),
        ("lastName", .lastName),
        ("surname", .lastName),
        ("name", .fullName),
        ("customer_name", .fullName),
        ("product_name", .text),
        ("phone_number", .phone),
        ("street_address", .streetAddress),
        ("city", .city),
        ("country", .country),
        ("zip_code", .pattern),
        ("website", .pattern),
        ("hotel", .text),
        ("notes", .text)
    ])
    func textKindFollowsTheName(name: String, expected: RowGeneratorKind) {
        #expect(RowGenerationDefaults.kind(for: Self.text(name)) == expected)
    }

    @Test("A column's type decides its generator before its name does")
    func typeDecidesFirst() {
        let table = RowGenerationTable(columns: [])
        func kind(_ column: RowGenerationColumn) -> RowGeneratorKind {
            RowGenerationDefaults.settings(for: column, in: table).kind
        }
        #expect(kind(RowGenerationColumn(name: "email", typeName: "uuid", valueClass: .uuid)) == .uuid)
        #expect(kind(RowGenerationColumn(name: "status", typeName: "status", valueClass: .enumeration(["new", "paid"]))) == .list)
        #expect(kind(RowGenerationColumn(name: "is_active", typeName: "boolean", valueClass: .boolean)) == .boolean)
        #expect(kind(RowGenerationColumn(name: "created_at", typeName: "timestamp", valueClass: .timestamp)) == .dateTime)
        #expect(kind(RowGenerationColumn(name: "meta", typeName: "jsonb", valueClass: .json)) == .json)
        #expect(kind(RowGenerationColumn(name: "photo", typeName: "bytea", valueClass: .unsupported)) == .serverDefault)
    }

    @Test("Identity, generated and foreign key columns start where the issue says they should")
    func ownershipAndReferencesComeFirst() {
        let table = RowGenerationTable(columns: [])
        let identity = RowGenerationColumn(
            name: "id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false, ownership: .assigned
        )
        let computed = RowGenerationColumn(name: "total", typeName: "int", valueClass: .integer(minimum: 0, maximum: 9), ownership: .computed)
        let foreignKey = RowGenerationColumn(
            name: "user_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false,
            reference: RowGenerationReferenceSlot(sourceId: "fk", position: 0)
        )

        #expect(RowGenerationDefaults.settings(for: identity, in: table).kind == .serverDefault)
        #expect(computed.availableKinds == [.serverDefault])
        #expect(RowGenerationDefaults.settings(for: foreignKey, in: table).kind == .reference)
        #expect(identity.availableKinds.first == .serverDefault)
        #expect(!foreignKey.availableKinds.contains(.serverDefault))
    }

    @Test("An enum column starts with its own labels")
    func enumStartsWithItsLabels() {
        let column = RowGenerationColumn(name: "status", typeName: "status", valueClass: .enumeration(["new", "paid", "shipped"]))
        let settings = RowGenerationDefaults.settings(for: column, in: RowGenerationTable(columns: [column]))

        #expect(settings.kind == .list)
        #expect(settings.values == ["new", "paid", "shipped"])
    }

    @Test("A key column's sequence starts past the largest value the table holds")
    func keySequenceStartsPastTheTable() {
        let key = RowGenerationColumn(
            name: "id", typeName: "int", valueClass: .integer(minimum: -2_147_483_648, maximum: 2_147_483_647), isNullable: false, isUnique: true
        )
        let empty = RowGenerationDefaults.settings(for: key, in: RowGenerationTable(columns: [key]))
        let filled = RowGenerationDefaults.settings(for: key, in: RowGenerationTable(columns: [key], keyMaximums: ["id": 41]))

        #expect(empty.kind == .sequence)
        #expect(empty.integerMinimum == 1)
        #expect(filled.integerMinimum == 42)
    }

    @Test("Ranges start inside what the column holds")
    func rangesFitTheColumn() {
        let tiny = RowGenerationColumn(name: "level", typeName: "tinyint", valueClass: .integer(minimum: -128, maximum: 127))
        let tinySettings = RowGenerationDefaults.settings(for: tiny, in: RowGenerationTable(columns: [tiny]))
        let money = RowGenerationColumn(name: "price", typeName: "numeric(4,2)", valueClass: .decimal(precision: 4, scale: 2))
        let moneySettings = RowGenerationDefaults.settings(for: money, in: RowGenerationTable(columns: [money]))
        let short = Self.text("code_name", maxLength: 10)
        let shortSettings = RowGenerationDefaults.settings(for: short, in: RowGenerationTable(columns: [short]))

        #expect(tinySettings.integerMaximum == 127)
        #expect(moneySettings.decimalMaximum <= 99.99)
        #expect(shortSettings.maxLength == 10)
        #expect(shortSettings.minLength <= 10)
    }

    @Test("A column name splits into words however it is written")
    func nameTokens() {
        #expect(RowGenerationDefaults.nameTokens("customerEmail") == ["customer", "email"])
        #expect(RowGenerationDefaults.nameTokens("CUSTOMER_EMAIL") == ["customer", "email"])
        #expect(RowGenerationDefaults.nameTokens("address-line2") == ["address", "line2"])
    }
}

struct RowGenerationColumnReaderTests {
    @Test("Columns the server fills are told apart from the ones it computes")
    func serverOwnership() {
        let reading = RowGenerationColumnReader.read(
            columns: [
                ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true, defaultValue: "nextval('orders_id_seq'::regclass)"),
                ColumnInfo(name: "code", dataType: "integer", isNullable: false, isPrimaryKey: false, identityKind: .byDefault),
                ColumnInfo(name: "total", dataType: "numeric(10,2)", isNullable: true, isPrimaryKey: false, isGenerated: true),
                ColumnInfo(name: "label", dataType: "text", isNullable: true, isPrimaryKey: false)
            ],
            foreignKeys: [],
            indexes: [],
            databaseType: .postgresql
        )

        #expect(reading.columns.map { $0.ownership } == [.assigned, .assigned, .computed, .none])
        #expect(reading.columns[0].isUnique)
    }

    @Test("SQLite's INTEGER PRIMARY KEY is the rowid, and any other key is not")
    func sqliteRowidAlias() {
        let rowid = RowGenerationColumnReader.read(
            columns: [ColumnInfo(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true)],
            foreignKeys: [], indexes: [], databaseType: .sqlite
        )
        let textKey = RowGenerationColumnReader.read(
            columns: [ColumnInfo(name: "id", dataType: "TEXT", isNullable: false, isPrimaryKey: true)],
            foreignKeys: [], indexes: [], databaseType: .sqlite
        )

        #expect(rowid.columns[0].ownership == .assigned)
        #expect(textKey.columns[0].ownership == .none)
    }

    @Test("An INTEGER PRIMARY KEY in a WITHOUT ROWID table needs a value of its own")
    func withoutRowIDKeyIsWritten() {
        let definition = "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT) STRICT, WITHOUT ROWID;"
        let reading = RowGenerationColumnReader.read(
            columns: [ColumnInfo(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true)],
            foreignKeys: [], indexes: [], databaseType: .sqlite,
            hasRowID: !RowGenerationColumnReader.declaresWithoutRowID(definition)
        )

        #expect(reading.columns[0].ownership == .none)
        #expect(!RowGenerationColumnReader.declaresWithoutRowID("CREATE TABLE t (note TEXT DEFAULT 'without rowid')"))
    }

    @Test("Unique indexes make a column unique alone or a key of several, and expressions are skipped")
    func uniqueKeys() {
        let reading = RowGenerationColumnReader.read(
            columns: [
                ColumnInfo(name: "email", dataType: "varchar(120)", isNullable: false, isPrimaryKey: false),
                ColumnInfo(name: "tenant", dataType: "int", isNullable: false, isPrimaryKey: false),
                ColumnInfo(name: "slug", dataType: "varchar(40)", isNullable: false, isPrimaryKey: false)
            ],
            foreignKeys: [],
            indexes: [
                IndexInfo(name: "email_key", columns: ["email"], isUnique: true, isPrimary: false, type: "BTREE"),
                IndexInfo(name: "slug_key", columns: ["tenant", "slug"], isUnique: true, isPrimary: false, type: "BTREE"),
                IndexInfo(name: "lower_slug", columns: ["lower(slug)"], isUnique: true, isPrimary: false, type: "BTREE"),
                IndexInfo(name: "plain", columns: ["slug"], isUnique: false, isPrimary: false, type: "BTREE")
            ],
            databaseType: .mysql
        )

        #expect(reading.columns.map { $0.isUnique } == [true, false, false])
        #expect(reading.uniqueGroups == [["tenant", "slug"]])
        #expect(reading.columns[0].valueClass == .text(maxLength: 120))
    }

    @Test("A foreign key over two columns is one source, read in the key's column order")
    func compositeForeignKey() {
        let reading = RowGenerationColumnReader.read(
            columns: [
                ColumnInfo(name: "shop_id", dataType: "int", isNullable: false, isPrimaryKey: false),
                ColumnInfo(name: "region", dataType: "varchar(4)", isNullable: false, isPrimaryKey: false),
                ColumnInfo(name: "owner_id", dataType: "int", isNullable: true, isPrimaryKey: false)
            ],
            foreignKeys: [
                ForeignKeyInfo(name: "fk_shop", column: "shop_id", referencedTable: "shops", referencedColumn: "id"),
                ForeignKeyInfo(name: "fk_shop", column: "region", referencedTable: "shops", referencedColumn: "region"),
                ForeignKeyInfo(name: "fk_owner", column: "owner_id", referencedTable: "users", referencedColumn: "id")
            ],
            indexes: [],
            databaseType: .mysql
        )

        #expect(reading.references.count == 2)
        #expect(reading.references[0].columns == ["shop_id", "region"])
        #expect(reading.references[0].referencedColumns == ["id", "region"])
        #expect(reading.columns[1].reference == RowGenerationReferenceSlot(sourceId: reading.references[0].id, position: 1))
        #expect(reading.columns[2].reference?.sourceId == reading.references[1].id)
    }

    @Test("Integer widths, MySQL's unsigned and YEAR, and enum labels come from the declared type")
    func valueClasses() {
        func valueClass(_ dataType: String, _ databaseType: DatabaseType, allowed: [String]? = nil) -> RowGenerationValueClass {
            RowGenerationColumnReader.valueClass(
                of: ColumnInfo(name: "c", dataType: dataType, isNullable: true, isPrimaryKey: false, allowedValues: allowed),
                family: SQLTypeFamily.of(databaseType)
            )
        }

        #expect(valueClass("tinyint unsigned", .mysql) == .integer(minimum: 0, maximum: 255))
        #expect(valueClass("smallint", .postgresql) == .integer(minimum: -32_768, maximum: 32_767))
        #expect(valueClass("year", .mysql) == .integer(minimum: 1_901, maximum: 2_155))
        #expect(valueClass("tinyint(1)", .mysql) == .boolean)
        #expect(valueClass("enum('a','b')", .mysql) == .enumeration(["a", "b"]))
        #expect(valueClass("mood", .postgresql, allowed: ["sad", "ok"]) == .enumeration(["sad", "ok"]))
        #expect(valueClass("numeric(8,2)", .postgresql) == .decimal(precision: 8, scale: 2))
        #expect(valueClass("timestamp with time zone", .postgresql) == .timestamp)
        #expect(valueClass("bytea", .postgresql) == .unsupported)
    }
}
