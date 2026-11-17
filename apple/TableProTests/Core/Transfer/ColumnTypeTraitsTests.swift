import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ColumnTypeTraitsTests {
    // One or more ids of every `SQLTypeFamily`, and engines that family leaves generic.
    private static let databaseTypeIds = [
        "MySQL", "MariaDB", "TiDB", "OceanBase", "StarRocks",
        "PostgreSQL", "Redshift", "CockroachDB", "PGlite", "KingbaseES", "Greenplum",
        "SQLite", "libSQL", "Cloudflare D1", "SQL Server", "Oracle", "Dameng", "ClickHouse", "DuckDB",
        "MongoDB", "Snowflake", "BigQuery"
    ]

    private static let typeNames = [
        "", " bit", "bit ", "BLOB", "blob", "BLOB SUB_TYPE 1", "BLOBTEXT", "BLOBINT", "TIMEBLOB", "tinyblob", "MEDIUMBLOB",
        "longblob", "bytea", "bytea[]", "BYTES", "bytes", "Bytes", "VARBINARY(16)", "varbinary(max)", "binary(16)",
        "BINARY_DOUBLE", "RAW(16)", "LONG RAW", "long raw", "IMAGE", "Nullable(String)", "LowCardinality(Nullable(String))",
        "Nullable(Bool)", "boolean", "BOOL", "_bool", "boolean[]", "ARRAY<BOOL>", "STRUCT<a BLOB>", "Array(Bool)",
        "MAP(String, Bool)", "tinyint(1)", "TINYINT(1) UNSIGNED", "tinyint( 1 )", "tinyint(4)", "TINYINT", "bit", "BIT",
        "bit(1)", "bit(8)", "BIT(64)", "bit varying(5)", "bit(3) varying", "varbit", "bit(1)[]", "BITSTRING",
        "INT(10) UNSIGNED ZEROFILL", "ENUM[](mood)", "varchar(255)", "text", "json", "uuid", "VARIANT", "geometry"
    ]

    @Test("The import reads bytes and flags from a type name as the classifier does", arguments: databaseTypeIds)
    func matchesTheClassifier(_ databaseTypeId: String) {
        let classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(DatabaseType(rawValue: databaseTypeId)))
        for name in Self.typeNames {
            let type = classifier.classify(rawTypeName: name)
            #expect(ColumnTypeTraits.holdsBytes(name) == type.isBlobType, "\(name) on \(databaseTypeId)")
            #expect(
                ColumnTypeTraits.isBooleanFlag(name, databaseTypeId: databaseTypeId) == type.isBooleanType,
                "\(name) on \(databaseTypeId)"
            )
        }
    }

    @Test("A boolean word becomes a digit only for a flag column on a dialect that writes numbers")
    func numericBooleansNeedBoth() {
        typealias Traits = ImportTargetValues.ColumnTraits
        #expect(Traits(typeName: "tinyint(1)", databaseTypeId: "MySQL", writesNumericBooleans: true).takesNumericBooleans)
        #expect(!Traits(typeName: "tinyint(1)", databaseTypeId: "MySQL", writesNumericBooleans: false).takesNumericBooleans)
        #expect(!Traits(typeName: "bit(8)", databaseTypeId: "MySQL", writesNumericBooleans: true).takesNumericBooleans)
        #expect(!Traits(typeName: "bit", databaseTypeId: "PostgreSQL", writesNumericBooleans: true).takesNumericBooleans)
        #expect(Traits(typeName: "LONG RAW", databaseTypeId: "Oracle", writesNumericBooleans: true).holdsBytes)
    }

    @Test("Text in a binary column is bytes only as 0x and an even run of hex digits")
    func prefixedHexReadsStrictly() {
        typealias PrefixedHex = ImportTargetValues.PrefixedHex
        #expect(PrefixedHex(reading: "0x00ff") == .bytes(Data([0x00, 0xFF])))
        #expect(PrefixedHex(reading: "0X") == .bytes(Data()))
        #expect(PrefixedHex(reading: "0x0") == .malformed)
        #expect(PrefixedHex(reading: "0xzz") == .malformed)
        #expect(PrefixedHex(reading: "plain") == .notHex)
    }
}
