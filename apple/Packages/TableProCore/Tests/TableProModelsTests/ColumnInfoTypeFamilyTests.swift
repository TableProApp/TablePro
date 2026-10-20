import Foundation
@testable import TableProModels
import Testing

struct ColumnInfoTypeFamilyTests {
    @Test(
        "JSON and JSONB columns read as JSON, wrapped or sized",
        arguments: ["json", "jsonb", "JSON", "JSONB", " json ", "Nullable(JSON)", "LowCardinality(JSON)", "json(max)"]
    )
    func jsonColumnsAreJSON(_ typeName: String) {
        #expect(ColumnInfo.isJSONType(typeName: typeName))
    }

    @Test(
        "Arrays of JSON, JSON paths and text types are not JSON",
        arguments: [
            "json[]", "jsonb[]", "_jsonb", "ARRAY", "Array(JSON)", "jsonpath", "JSONPATH", "longtext", "VARCHAR",
            "text", "unknown", ""
        ]
    )
    func otherColumnsAreNotJSON(_ typeName: String) {
        #expect(ColumnInfo.isJSONType(typeName: typeName) == false)
    }

    @Test(
        "Integer and decimal families are numeric",
        arguments: [
            "INT", "int4", "integer", "BIGINT UNSIGNED", "smallint", "TINYINT(1)", "serial", "Int64", "UInt8",
            "Nullable(Int32)", "HUGEINT", "DECIMAL(10,2)", "Decimal128(3)", "numeric", "NUMBER(10)", "DOUBLE",
            "double precision", "FLOAT8", "Float32", "REAL", "money", "BINARY_DOUBLE"
        ]
    )
    func numericColumnsAreNumeric(_ typeName: String) {
        #expect(ColumnInfo.isNumericType(typeName: typeName))
    }

    @Test(
        "Types whose name only contains INT, and arrays of numbers, are not numeric",
        arguments: [
            "INTERVAL", "interval day to second", "POINT", "MULTIPOINT", "integer[]", "ARRAY", "Array(Int32)",
            "VARCHAR(10)", "TEXT", "BIT", "BOOLEAN", "DATE", "JSON", "unknown", ""
        ]
    )
    func otherColumnsAreNotNumeric(_ typeName: String) {
        #expect(ColumnInfo.isNumericType(typeName: typeName) == false)
    }

    @Test(
        "Text columns and names this does not know may hold JSON text",
        arguments: ["text", "varchar(255)", "nvarchar(max)", "LONGTEXT", "CLOB", "citext", "Nullable(String)", "USER-DEFINED", ""]
    )
    func textColumnsMayHoldJSONText(_ typeName: String) {
        #expect(ColumnInfo.mayHoldJSONText(typeName: typeName))
    }

    @Test(
        "Arrays, lists, structs, maps, unknown types and typed columns do not",
        arguments: [
            "unknown", "int[]", "ARRAY", "INTEGER[]", "VARCHAR[]", "LIST", "STRUCT(a INTEGER)", "MAP(VARCHAR, INTEGER)",
            "Map(String, UInt64)", "jsonb", "JSON", "integer", "uuid", "timestamp"
        ]
    )
    func nestedAndTypedColumnsDoNotHoldJSONText(_ typeName: String) {
        #expect(ColumnInfo.mayHoldJSONText(typeName: typeName) == false)
    }

    @Test("The properties read the column's own type name")
    func propertiesReadTypeName() {
        let document = ColumnInfo(name: "doc", typeName: "jsonb", ordinalPosition: 0)
        let count = ColumnInfo(name: "count", typeName: "INTEGER", ordinalPosition: 1)
        let note = ColumnInfo(name: "note", typeName: "TEXT", ordinalPosition: 2)
        #expect(document.isJSONType)
        #expect(document.mayHoldJSONText == false)
        #expect(count.isNumericType)
        #expect(count.isJSONType == false)
        #expect(note.mayHoldJSONText)
        #expect(note.isNumericType == false)
    }
}
