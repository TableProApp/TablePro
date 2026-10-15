import Foundation
import Testing

@testable import TableProModels

@Suite("ColumnInfo empty value")
struct ColumnInfoEmptyValueTests {
    @Test(
        "Dates, numbers, booleans and other typed values have no empty value",
        arguments: [
            "DATETIME", "datetime(6)", "TIMESTAMP", "timestamptz", "DATE", "TIME", "YEAR",
            "INT", "int4", "BIGINT UNSIGNED", "DECIMAL(10,2)", "numeric", "DOUBLE", "MONEY",
            "TINYINT(1)", "BIT", "bool", "JSON", "jsonb", "uuid", "uniqueidentifier", "inet",
            "geometry", "interval", "integer[]", "Nullable(UUID)", "enum('a','b')", "BINARY_DOUBLE",
            "timestamp without time zone", "double precision", "Int64", "DateTime64(3)", "FLOAT8"
        ]
    )
    func typedColumnsHaveNoEmptyValue(_ typeName: String) {
        #expect(ColumnInfo.holdsEmptyString(typeName: typeName) == false)
    }

    @Test(
        "Character, binary and SET columns, and types this does not know, hold the empty string",
        arguments: [
            "VARCHAR(64)", "character varying", "TEXT", "LONGTEXT", "NVARCHAR(MAX)", "bpchar",
            "citext", "CLOB", "BLOB", "bytea", "VARBINARY(16)", "set('x','y')", "enum('','a')",
            "Nullable(String)", "LowCardinality(String)", "", "USER-DEFINED", "mood", "bit varying"
        ]
    )
    func characterColumnsHoldEmptyValue(_ typeName: String) {
        #expect(ColumnInfo.holdsEmptyString(typeName: typeName))
    }

    @Test("The property reads the column's own type name")
    func propertyReadsTypeName() {
        #expect(ColumnInfo(name: "deleted_at", typeName: "DATETIME", ordinalPosition: 0).holdsEmptyString == false)
        #expect(ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1).holdsEmptyString)
    }
}
