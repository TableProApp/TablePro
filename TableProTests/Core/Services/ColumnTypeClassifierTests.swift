//
//  ColumnTypeClassifierTests.swift
//  TableProTests
//
//  Tests for ColumnTypeClassifier raw type name to ColumnType mapping.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column Type Classifier")
struct ColumnTypeClassifierTests {
    private let classifier = ColumnTypeClassifier()

    // MARK: - Helpers

    private func isText(_ type: ColumnType) -> Bool {
        if case .text = type { return true }
        return false
    }

    private func isInteger(_ type: ColumnType) -> Bool {
        if case .integer = type { return true }
        return false
    }

    private func isDecimal(_ type: ColumnType) -> Bool {
        if case .decimal = type { return true }
        return false
    }

    private func isDate(_ type: ColumnType) -> Bool {
        if case .date = type { return true }
        return false
    }

    private func isTimestamp(_ type: ColumnType) -> Bool {
        if case .timestamp = type { return true }
        return false
    }

    private func isDatetime(_ type: ColumnType) -> Bool {
        if case .datetime = type { return true }
        return false
    }

    private func isSpatial(_ type: ColumnType) -> Bool {
        if case .spatial = type { return true }
        return false
    }

    // MARK: - Generic / Wrapper Stripping

    @Suite("Generic / Wrapper Stripping")
    struct WrapperTests {
        private let classifier = ColumnTypeClassifier()

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isDatetime(_ type: ColumnType) -> Bool {
            if case .datetime = type { return true }
            return false
        }

        @Test("Nullable(String) classifies as text")
        func nullableString() {
            let result = classifier.classify(rawTypeName: "Nullable(String)")
            #expect(isText(result))
        }

        @Test("LowCardinality(String) classifies as text")
        func lowCardinalityString() {
            let result = classifier.classify(rawTypeName: "LowCardinality(String)")
            #expect(isText(result))
        }

        @Test("LowCardinality(Nullable(UInt32)) classifies as integer")
        func nestedWrappers() {
            let result = classifier.classify(rawTypeName: "LowCardinality(Nullable(UInt32))")
            #expect(isInteger(result))
        }

        @Test("Nullable(DateTime64(3)) classifies as datetime")
        func nullableDatetime64() {
            let result = classifier.classify(rawTypeName: "Nullable(DateTime64(3))")
            #expect(isDatetime(result))
        }

        @Test("Nullable(Enum8('a' = 1)) classifies as enum")
        func nullableEnum() {
            let result = classifier.classify(rawTypeName: "Nullable(Enum8('a' = 1))")
            #expect(result.isEnumType)
        }

        @Test("Nullable(Enum8('a' = 1, 'b' = 2)) classifies as enum")
        func nullableEnumMultiValue() {
            let result = classifier.classify(rawTypeName: "Nullable(Enum8('a' = 1, 'b' = 2))")
            #expect(result.isEnumType)
        }

        @Test("Empty string classifies as text")
        func emptyString() {
            let result = classifier.classify(rawTypeName: "")
            #expect(isText(result))
        }
    }

    // MARK: - MySQL Types

    @Suite("MySQL Types")
    struct MySQLTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isDate(_ type: ColumnType) -> Bool {
            if case .date = type { return true }
            return false
        }

        private func isDatetime(_ type: ColumnType) -> Bool {
            if case .datetime = type { return true }
            return false
        }

        private func isTimestamp(_ type: ColumnType) -> Bool {
            if case .timestamp = type { return true }
            return false
        }

        private func isSpatial(_ type: ColumnType) -> Bool {
            if case .spatial = type { return true }
            return false
        }

        @Test("TINYINT(1) classifies as boolean (MySQL convention)")
        func tinyint1IsBoolean() {
            #expect(classifier.classify(rawTypeName: "TINYINT(1)").isBooleanType)
        }

        @Test("TINYINT classifies as integer")
        func tinyintIsInteger() {
            #expect(isInteger(classifier.classify(rawTypeName: "TINYINT")))
        }

        @Test("TINYINT(4) classifies as integer, not boolean")
        func tinyint4IsInteger() {
            let result = classifier.classify(rawTypeName: "TINYINT(4)")
            #expect(isInteger(result))
            #expect(!result.isBooleanType)
        }

        @Test("INT(11) classifies as integer")
        func int11() {
            #expect(isInteger(classifier.classify(rawTypeName: "INT(11)")))
        }

        @Test("BIGINT(20) classifies as integer")
        func bigint20() {
            #expect(isInteger(classifier.classify(rawTypeName: "BIGINT(20)")))
        }

        @Test("MEDIUMINT(8) classifies as integer")
        func mediumint8() {
            #expect(isInteger(classifier.classify(rawTypeName: "MEDIUMINT(8)")))
        }

        @Test("SMALLINT classifies as integer")
        func smallint() {
            #expect(isInteger(classifier.classify(rawTypeName: "SMALLINT")))
        }

        @Test("ENUM('a','b','c') classifies as enum")
        func enumType() {
            #expect(classifier.classify(rawTypeName: "ENUM('a','b','c')").isEnumType)
        }

        @Test("SET('x','y') classifies as set")
        func setType() {
            #expect(classifier.classify(rawTypeName: "SET('x','y')").isSetType)
        }

        @Test("FLOAT classifies as decimal")
        func floatType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "FLOAT")))
        }

        @Test("DOUBLE classifies as decimal")
        func doubleType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "DOUBLE")))
        }

        @Test("DECIMAL(10,2) classifies as decimal")
        func decimalType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "DECIMAL(10,2)")))
        }

        @Test("NUMERIC(5) classifies as decimal")
        func numericType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "NUMERIC(5)")))
        }

        @Test("JSON classifies as json")
        func jsonType() {
            #expect(classifier.classify(rawTypeName: "JSON").isJsonType)
        }

        @Test("BLOB classifies as blob")
        func blobType() {
            #expect(classifier.classify(rawTypeName: "BLOB").isBlobType)
        }

        @Test("TINYBLOB classifies as blob")
        func tinyblobType() {
            #expect(classifier.classify(rawTypeName: "TINYBLOB").isBlobType)
        }

        @Test("MEDIUMBLOB classifies as blob")
        func mediumblobType() {
            #expect(classifier.classify(rawTypeName: "MEDIUMBLOB").isBlobType)
        }

        @Test("LONGBLOB classifies as blob")
        func longblobType() {
            #expect(classifier.classify(rawTypeName: "LONGBLOB").isBlobType)
        }

        @Test("BINARY classifies as blob")
        func binaryType() {
            #expect(classifier.classify(rawTypeName: "BINARY").isBlobType)
        }

        @Test("VARBINARY classifies as blob")
        func varbinaryType() {
            #expect(classifier.classify(rawTypeName: "VARBINARY").isBlobType)
        }

        @Test("BOOLEAN classifies as boolean")
        func booleanType() {
            #expect(classifier.classify(rawTypeName: "BOOLEAN").isBooleanType)
        }

        @Test("BOOL classifies as boolean")
        func boolType() {
            #expect(classifier.classify(rawTypeName: "BOOL").isBooleanType)
        }

        @Test("DATE classifies as date")
        func dateType() {
            #expect(isDate(classifier.classify(rawTypeName: "DATE")))
        }

        @Test("DATETIME classifies as datetime")
        func datetimeType() {
            #expect(isDatetime(classifier.classify(rawTypeName: "DATETIME")))
        }

        @Test("TIMESTAMP classifies as timestamp")
        func timestampType() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP")))
        }

        @Test("TIME classifies as timestamp")
        func timeType() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIME")))
        }

        @Test("TEXT classifies as text")
        func textType() {
            #expect(isText(classifier.classify(rawTypeName: "TEXT")))
        }

        @Test("VARCHAR(255) classifies as text")
        func varcharType() {
            #expect(isText(classifier.classify(rawTypeName: "VARCHAR(255)")))
        }

        @Test("LONGTEXT classifies as text")
        func longtextType() {
            #expect(isText(classifier.classify(rawTypeName: "LONGTEXT")))
        }

        @Test("GEOMETRY classifies as spatial")
        func geometryType() {
            #expect(isSpatial(classifier.classify(rawTypeName: "GEOMETRY")))
        }

        @Test("POINT classifies as spatial")
        func pointType() {
            #expect(isSpatial(classifier.classify(rawTypeName: "POINT")))
        }
    }

    // MARK: - MSSQL Types

    @Suite("MSSQL Types")
    struct MSSQLTests {
        private let classifier = ColumnTypeClassifier()

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isDatetime(_ type: ColumnType) -> Bool {
            if case .datetime = type { return true }
            return false
        }

        @Test("BIT classifies as boolean")
        func bitType() {
            #expect(classifier.classify(rawTypeName: "BIT").isBooleanType)
        }

        @Test("bit (lowercase) classifies as boolean")
        func bitLowercase() {
            #expect(classifier.classify(rawTypeName: "bit").isBooleanType)
        }

        @Test("MONEY classifies as decimal")
        func moneyType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "MONEY")))
        }

        @Test("SMALLMONEY classifies as decimal")
        func smallmoneyType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "SMALLMONEY")))
        }

        @Test("IMAGE classifies as blob")
        func imageType() {
            #expect(classifier.classify(rawTypeName: "IMAGE").isBlobType)
        }

        @Test("VARBINARY(MAX) classifies as blob")
        func varbinaryMax() {
            #expect(classifier.classify(rawTypeName: "VARBINARY(MAX)").isBlobType)
        }

        @Test("VARBINARY(100) classifies as blob")
        func varbinary100() {
            #expect(classifier.classify(rawTypeName: "VARBINARY(100)").isBlobType)
        }

        @Test("BINARY(16) classifies as blob")
        func binary16() {
            #expect(classifier.classify(rawTypeName: "BINARY(16)").isBlobType)
        }

        @Test("DATETIME2 classifies as datetime")
        func datetime2() {
            #expect(isDatetime(classifier.classify(rawTypeName: "DATETIME2")))
        }

        @Test("DATETIMEOFFSET classifies as datetime")
        func datetimeoffset() {
            #expect(isDatetime(classifier.classify(rawTypeName: "DATETIMEOFFSET")))
        }

        @Test("SMALLDATETIME classifies as datetime")
        func smalldatetime() {
            #expect(isDatetime(classifier.classify(rawTypeName: "SMALLDATETIME")))
        }

        @Test("NVARCHAR(MAX) classifies as text")
        func nvarcharMax() {
            #expect(isText(classifier.classify(rawTypeName: "NVARCHAR(MAX)")))
        }

        @Test("NTEXT classifies as text")
        func ntextType() {
            #expect(isText(classifier.classify(rawTypeName: "NTEXT")))
        }

        @Test("UNIQUEIDENTIFIER classifies as text")
        func uniqueidentifier() {
            #expect(isText(classifier.classify(rawTypeName: "UNIQUEIDENTIFIER")))
        }

        @Test("SQL_VARIANT classifies as text")
        func sqlVariant() {
            #expect(isText(classifier.classify(rawTypeName: "SQL_VARIANT")))
        }
    }

    // MARK: - ClickHouse Types

    @Suite("ClickHouse Types")
    struct ClickHouseTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isDate(_ type: ColumnType) -> Bool {
            if case .date = type { return true }
            return false
        }

        private func isDatetime(_ type: ColumnType) -> Bool {
            if case .datetime = type { return true }
            return false
        }

        @Test("DateTime64(3) classifies as datetime")
        func datetime64() {
            #expect(isDatetime(classifier.classify(rawTypeName: "DateTime64(3)")))
        }

        @Test("DateTime64(3, 'UTC') classifies as datetime")
        func datetime64WithTimezone() {
            #expect(isDatetime(classifier.classify(rawTypeName: "DateTime64(3, 'UTC')")))
        }

        @Test("Enum8('a' = 1, 'b' = 2) classifies as enum")
        func enum8() {
            #expect(classifier.classify(rawTypeName: "Enum8('a' = 1, 'b' = 2)").isEnumType)
        }

        @Test("Enum16('x' = 1) classifies as enum")
        func enum16() {
            #expect(classifier.classify(rawTypeName: "Enum16('x' = 1)").isEnumType)
        }

        @Test("Float32 classifies as decimal")
        func float32() {
            #expect(isDecimal(classifier.classify(rawTypeName: "Float32")))
        }

        @Test("Float64 classifies as decimal")
        func float64() {
            #expect(isDecimal(classifier.classify(rawTypeName: "Float64")))
        }

        @Test("Decimal128(3) classifies as decimal")
        func decimal128() {
            #expect(isDecimal(classifier.classify(rawTypeName: "Decimal128(3)")))
        }

        @Test("Int8 classifies as integer")
        func int8() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int8")))
        }

        @Test("Int16 classifies as integer")
        func int16() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int16")))
        }

        @Test("Int32 classifies as integer")
        func int32() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int32")))
        }

        @Test("Int64 classifies as integer")
        func int64() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int64")))
        }

        @Test("Int128 classifies as integer")
        func int128() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int128")))
        }

        @Test("Int256 classifies as integer")
        func int256() {
            #expect(isInteger(classifier.classify(rawTypeName: "Int256")))
        }

        @Test("UInt8 classifies as integer")
        func uint8() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt8")))
        }

        @Test("UInt16 classifies as integer")
        func uint16() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt16")))
        }

        @Test("UInt32 classifies as integer")
        func uint32() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt32")))
        }

        @Test("UInt64 classifies as integer")
        func uint64() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt64")))
        }

        @Test("UInt128 classifies as integer")
        func uint128() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt128")))
        }

        @Test("UInt256 classifies as integer")
        func uint256() {
            #expect(isInteger(classifier.classify(rawTypeName: "UInt256")))
        }

        @Test("Date32 classifies as date")
        func date32() {
            #expect(isDate(classifier.classify(rawTypeName: "Date32")))
        }

        @Test("Bool classifies as boolean")
        func boolType() {
            #expect(classifier.classify(rawTypeName: "Bool").isBooleanType)
        }

        @Test("UUID classifies as text")
        func uuidType() {
            #expect(isText(classifier.classify(rawTypeName: "UUID")))
        }

        @Test("FixedString(36) classifies as text")
        func fixedString() {
            #expect(isText(classifier.classify(rawTypeName: "FixedString(36)")))
        }

        @Test("String classifies as text")
        func stringType() {
            #expect(isText(classifier.classify(rawTypeName: "String")))
        }
    }

    // MARK: - DuckDB Types

    @Suite("DuckDB Types")
    struct DuckDBTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isTimestamp(_ type: ColumnType) -> Bool {
            if case .timestamp = type { return true }
            return false
        }

        @Test("UTINYINT classifies as integer")
        func utinyint() {
            #expect(isInteger(classifier.classify(rawTypeName: "UTINYINT")))
        }

        @Test("USMALLINT classifies as integer")
        func usmallint() {
            #expect(isInteger(classifier.classify(rawTypeName: "USMALLINT")))
        }

        @Test("UINTEGER classifies as integer")
        func uinteger() {
            #expect(isInteger(classifier.classify(rawTypeName: "UINTEGER")))
        }

        @Test("UBIGINT classifies as integer")
        func ubigint() {
            #expect(isInteger(classifier.classify(rawTypeName: "UBIGINT")))
        }

        @Test("HUGEINT classifies as integer")
        func hugeint() {
            #expect(isInteger(classifier.classify(rawTypeName: "HUGEINT")))
        }

        @Test("UHUGEINT classifies as integer")
        func uhugeint() {
            #expect(isInteger(classifier.classify(rawTypeName: "UHUGEINT")))
        }

        @Test("ENUM classifies as enum")
        func enumType() {
            #expect(classifier.classify(rawTypeName: "ENUM").isEnumType)
        }

        @Test("BOOLEAN classifies as boolean")
        func booleanType() {
            #expect(classifier.classify(rawTypeName: "BOOLEAN").isBooleanType)
        }

        @Test("BLOB classifies as blob")
        func blobType() {
            #expect(classifier.classify(rawTypeName: "BLOB").isBlobType)
        }

        @Test("TIMESTAMP_S classifies as timestamp")
        func timestampS() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP_S")))
        }

        @Test("TIMESTAMP_MS classifies as timestamp")
        func timestampMs() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP_MS")))
        }

        @Test("TIMESTAMP_NS classifies as timestamp")
        func timestampNs() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP_NS")))
        }

        @Test("TIMESTAMPTZ classifies as timestamp")
        func timestamptz() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMPTZ")))
        }
    }

    // MARK: - PostgreSQL Types

    @Suite("PostgreSQL Types")
    struct PostgreSQLTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isTimestamp(_ type: ColumnType) -> Bool {
            if case .timestamp = type { return true }
            return false
        }

        @Test("BOOLEAN classifies as boolean")
        func booleanType() {
            #expect(classifier.classify(rawTypeName: "BOOLEAN").isBooleanType)
        }

        @Test("boolean (lowercase) classifies as boolean")
        func booleanLowercase() {
            #expect(classifier.classify(rawTypeName: "boolean").isBooleanType)
        }

        @Test("SERIAL classifies as integer")
        func serialType() {
            #expect(isInteger(classifier.classify(rawTypeName: "SERIAL")))
        }

        @Test("BIGSERIAL classifies as integer")
        func bigserialType() {
            #expect(isInteger(classifier.classify(rawTypeName: "BIGSERIAL")))
        }

        @Test("SMALLSERIAL classifies as integer")
        func smallserialType() {
            #expect(isInteger(classifier.classify(rawTypeName: "SMALLSERIAL")))
        }

        @Test("JSONB classifies as json")
        func jsonbType() {
            #expect(classifier.classify(rawTypeName: "JSONB").isJsonType)
        }

        @Test("BYTEA classifies as blob")
        func byteaType() {
            #expect(classifier.classify(rawTypeName: "BYTEA").isBlobType)
        }

        @Test("TIMESTAMPTZ classifies as timestamp")
        func timestamptz() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMPTZ")))
        }

        @Test("ENUM(mood) classifies as enum")
        func enumMood() {
            #expect(classifier.classify(rawTypeName: "ENUM(mood)").isEnumType)
        }

        @Test("MONEY classifies as decimal")
        func moneyType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "MONEY")))
        }

        @Test("DOUBLE PRECISION classifies as decimal")
        func doublePrecision() {
            #expect(isDecimal(classifier.classify(rawTypeName: "DOUBLE PRECISION")))
        }
    }

    // MARK: - SQLite Types

    @Suite("SQLite Types")
    struct SQLiteTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        @Test("INTEGER classifies as integer")
        func integerType() {
            #expect(isInteger(classifier.classify(rawTypeName: "INTEGER")))
        }

        @Test("REAL classifies as decimal")
        func realType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "REAL")))
        }

        @Test("BLOB classifies as blob")
        func blobType() {
            #expect(classifier.classify(rawTypeName: "BLOB").isBlobType)
        }

        @Test("TEXT classifies as text")
        func textType() {
            #expect(isText(classifier.classify(rawTypeName: "TEXT")))
        }

        @Test("NUMERIC classifies as decimal")
        func numericType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "NUMERIC")))
        }
    }

    // MARK: - Oracle Types

    @Suite("Oracle Types")
    struct OracleTests {
        private let classifier = ColumnTypeClassifier()

        private func isDecimal(_ type: ColumnType) -> Bool {
            if case .decimal = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isTimestamp(_ type: ColumnType) -> Bool {
            if case .timestamp = type { return true }
            return false
        }

        @Test("NUMBER classifies as decimal")
        func numberType() {
            #expect(isDecimal(classifier.classify(rawTypeName: "NUMBER")))
        }

        @Test("NUMBER(10,2) classifies as decimal")
        func numberWithParams() {
            #expect(isDecimal(classifier.classify(rawTypeName: "NUMBER(10,2)")))
        }

        @Test("VARCHAR2(50) classifies as text")
        func varchar2() {
            #expect(isText(classifier.classify(rawTypeName: "VARCHAR2(50)")))
        }

        @Test("CLOB classifies as text")
        func clobType() {
            #expect(isText(classifier.classify(rawTypeName: "CLOB")))
        }

        @Test("RAW classifies as blob")
        func rawType() {
            #expect(classifier.classify(rawTypeName: "RAW").isBlobType)
        }

        @Test("TIMESTAMP WITH TIME ZONE classifies as timestamp")
        func timestampWithTimeZone() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP WITH TIME ZONE")))
        }
    }

    // MARK: - Fallback Patterns

    @Suite("Fallback Patterns")
    struct FallbackTests {
        private let classifier = ColumnTypeClassifier()

        private func isInteger(_ type: ColumnType) -> Bool {
            if case .integer = type { return true }
            return false
        }

        private func isText(_ type: ColumnType) -> Bool {
            if case .text = type { return true }
            return false
        }

        private func isTimestamp(_ type: ColumnType) -> Bool {
            if case .timestamp = type { return true }
            return false
        }

        @Test("BIGSERIAL falls back to integer via SERIAL suffix")
        func bigserialFallback() {
            #expect(isInteger(classifier.classify(rawTypeName: "BIGSERIAL")))
        }

        @Test("SMALLSERIAL falls back to integer via SERIAL suffix")
        func smallserialFallback() {
            #expect(isInteger(classifier.classify(rawTypeName: "SMALLSERIAL")))
        }

        @Test("MEDIUMTEXT falls back to text via TEXT suffix")
        func mediumtextFallback() {
            #expect(isText(classifier.classify(rawTypeName: "MEDIUMTEXT")))
        }

        @Test("TINYTEXT falls back to text via TEXT suffix")
        func tinytextFallback() {
            #expect(isText(classifier.classify(rawTypeName: "TINYTEXT")))
        }

        @Test("TIMESTAMP WITH LOCAL TIME ZONE falls back to timestamp via prefix")
        func timestampWithLocalTz() {
            #expect(isTimestamp(classifier.classify(rawTypeName: "TIMESTAMP WITH LOCAL TIME ZONE")))
        }

        @Test("LONGBLOB falls back to blob via contains BLOB")
        func longblobFallback() {
            #expect(classifier.classify(rawTypeName: "LONGBLOB").isBlobType)
        }

        @Test("unknown_type_xyz falls back to text")
        func unknownFallback() {
            #expect(isText(classifier.classify(rawTypeName: "unknown_type_xyz")))
        }
    }
}
