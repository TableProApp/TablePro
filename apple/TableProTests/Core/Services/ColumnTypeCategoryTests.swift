//
//  ColumnTypeCategoryTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct ColumnTypeCategoryTests {
    private func expectCategories(
        _ family: SQLTypeFamily?,
        _ cases: KeyValuePairs<String, ColumnTypeCategory>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let classifier = ColumnTypeClassifier(family: family)
        for (rawType, expected) in cases {
            let category = ColumnTypeCategory(classifier.classify(rawTypeName: rawType))
            #expect(category == expected, "\(rawType)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Engine families

    @Test("MySQL's common types land in their categories")
    func mysql() {
        expectCategories(.mysql, [
            "varchar(255)": .text,
            "char(36)": .text,
            "longtext": .text,
            "int(11)": .number,
            "bigint(20) unsigned": .number,
            "decimal(10,2)": .number,
            "double": .number,
            "tinyint(1)": .boolean,
            "bit(1)": .boolean,
            "datetime": .dateTime,
            "timestamp": .dateTime,
            "date": .dateTime,
            "time": .dateTime,
            "year(4)": .dateTime,
            "json": .document,
            "blob": .binary,
            "varbinary(16)": .binary,
            "geometry": .spatial,
            "point": .spatial,
            "enum('draft','sent')": .other,
            "set('red','blue')": .other,
        ])
    }

    @Test("PostgreSQL's common types land in their categories")
    func postgres() {
        expectCategories(.postgres, [
            "character varying(255)": .text,
            "text": .text,
            "uuid": .text,
            "integer": .number,
            "bigint": .number,
            "numeric(10,2)": .number,
            "double precision": .number,
            "boolean": .boolean,
            "timestamp with time zone": .dateTime,
            "time without time zone": .dateTime,
            "date": .dateTime,
            "interval": .dateTime,
            "bytea": .binary,
            "jsonb": .document,
            "xml": .document,
            "hstore": .document,
            "integer[]": .document,
            "text[]": .document,
            "geometry": .spatial,
            "geography(Point,4326)": .spatial,
            "vector(3)": .other,
        ])
    }

    @Test("SQLite's common types land in their categories")
    func sqlite() {
        expectCategories(.sqlite, [
            "TEXT": .text,
            "VARCHAR(50)": .text,
            "INTEGER": .number,
            "REAL": .number,
            "NUMERIC": .number,
            "BOOLEAN": .boolean,
            "DATETIME": .dateTime,
            "BLOB": .binary,
        ])
    }

    @Test("SQL Server's common types land in their categories")
    func mssql() {
        expectCategories(.mssql, [
            "nvarchar(50)": .text,
            "uniqueidentifier": .text,
            "int": .number,
            "decimal(18,2)": .number,
            "money": .number,
            "bit": .boolean,
            "datetime2(7)": .dateTime,
            "datetimeoffset": .dateTime,
            "varbinary(max)": .binary,
            "xml": .document,
            "geography": .spatial,
        ])
    }

    @Test("Oracle's common types land in their categories")
    func oracle() {
        expectCategories(.oracle, [
            "VARCHAR2(100)": .text,
            "CLOB": .text,
            "NUMBER(10,2)": .number,
            "BINARY_DOUBLE": .number,
            "DATE": .dateTime,
            "TIMESTAMP(6)": .dateTime,
            "TIMESTAMP(6) WITH TIME ZONE": .dateTime,
            "INTERVAL DAY(2) TO SECOND(6)": .dateTime,
            "BLOB": .binary,
            "RAW(16)": .binary,
            "SDO_GEOMETRY": .spatial,
        ])
    }

    @Test("ClickHouse's common types land in their categories, through Nullable and LowCardinality")
    func clickhouse() {
        expectCategories(.clickhouse, [
            "String": .text,
            "Nullable(String)": .text,
            "LowCardinality(String)": .text,
            "UUID": .text,
            "UInt64": .number,
            "Float64": .number,
            "Decimal(18, 4)": .number,
            "Bool": .boolean,
            "Date32": .dateTime,
            "DateTime64(3)": .dateTime,
            "Array(String)": .document,
            "Map(String, UInt64)": .document,
            "Point": .spatial,
            "Enum8('a' = 1, 'b' = 2)": .other,
        ])
    }

    @Test("DuckDB's common types land in their categories")
    func duckdb() {
        expectCategories(.duckdb, [
            "VARCHAR": .text,
            "HUGEINT": .number,
            "DOUBLE": .number,
            "BOOLEAN": .boolean,
            "TIMESTAMPTZ": .dateTime,
            "INTERVAL": .dateTime,
            "BLOB": .binary,
            "JSON": .document,
            "INTEGER[]": .document,
            "STRUCT(a INTEGER)": .document,
        ])
    }

    @Test("A document store's sampled types land in their categories")
    func documentStore() {
        expectCategories(nil, [
            "VARCHAR": .text,
            "ObjectId": .text,
            "INTEGER": .number,
            "BIGINT": .number,
            "FLOAT": .number,
            "BOOLEAN": .boolean,
            "TIMESTAMP": .dateTime,
            "JSON": .document,
            "BLOB": .binary,
        ])
    }

    // MARK: - Every case

    @Test("Each column type falls in one category, with no raw type as well as with one")
    func everyColumnTypeHasACategory() {
        let cases: [(ColumnType, ColumnTypeCategory)] = [
            (.text(rawType: nil), .text),
            (.integer(rawType: nil), .number),
            (.decimal(rawType: nil), .number),
            (.date(rawType: nil), .dateTime),
            (.timestamp(rawType: nil), .dateTime),
            (.datetime(rawType: nil), .dateTime),
            (.boolean(rawType: nil), .boolean),
            (.blob(rawType: nil), .binary),
            (.json(rawType: nil), .document),
            (.array(rawType: nil, element: .integer(rawType: nil)), .document),
            (.spatial(rawType: nil), .spatial),
            (.enumType(rawType: nil, values: ["a"]), .other),
            (.set(rawType: nil, values: nil), .other),
            (.vector(rawType: nil), .other),
        ]
        for (type, expected) in cases {
            #expect(ColumnTypeCategory(type) == expected, "\(type)")
        }
    }

    @Test("Every category has its own glyph, and the system has each one")
    func everyCategoryHasAGlyph() {
        let names = ColumnTypeCategory.allCases.map { $0.symbolName }

        #expect(Set(names).count == ColumnTypeCategory.allCases.count)
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
