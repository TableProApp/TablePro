//
//  ColumnTypeBadgeLabelTests.swift
//  TableProTests
//
//  Tests for ColumnType.badgeLabel, covering Redis-specific overrides
//  and all standard badge labels.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ColumnType Badge Labels")
struct ColumnTypeBadgeLabelTests {
    // MARK: - Redis-Specific Overrides

    @Test("RedisType enum returns option")
    func redisTypeEnumReturnsOption() {
        let type = ColumnType.enumType(rawType: "RedisType", values: ["string", "list", "set"])
        #expect(type.badgeLabel == "option")
    }

    @Test("RedisInt integer returns second")
    func redisIntIntegerReturnsSecond() {
        let type = ColumnType.integer(rawType: "RedisInt")
        #expect(type.badgeLabel == "second")
    }

    @Test("RedisRaw text returns raw")
    func redisRawTextReturnsRaw() {
        let type = ColumnType.text(rawType: "RedisRaw")
        #expect(type.badgeLabel == "raw")
    }

    // MARK: - Standard Labels

    @Test("Standard text returns string")
    func standardTextReturnsString() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        #expect(type.badgeLabel == "string")
    }

    @Test("Standard integer returns number")
    func standardIntegerReturnsNumber() {
        let type = ColumnType.integer(rawType: "INT")
        #expect(type.badgeLabel == "number")
    }

    @Test("Standard enum returns enum")
    func standardEnumReturnsEnum() {
        let type = ColumnType.enumType(rawType: "ENUM('a','b')", values: ["a", "b"])
        #expect(type.badgeLabel == "enum")
    }

    @Test("Boolean returns bool")
    func booleanReturnsBool() {
        let type = ColumnType.boolean(rawType: "TINYINT(1)")
        #expect(type.badgeLabel == "bool")
    }

    @Test("JSON returns json")
    func jsonReturnsJson() {
        let type = ColumnType.json(rawType: "JSON")
        #expect(type.badgeLabel == "json")
    }

    @Test("Date returns date")
    func dateReturnsDate() {
        let type = ColumnType.date(rawType: "DATE")
        #expect(type.badgeLabel == "date")
    }

    @Test("Timestamp returns date")
    func timestampReturnsDate() {
        let type = ColumnType.timestamp(rawType: "TIMESTAMP")
        #expect(type.badgeLabel == "date")
    }

    @Test("Datetime returns date")
    func datetimeReturnsDate() {
        let type = ColumnType.datetime(rawType: "DATETIME")
        #expect(type.badgeLabel == "date")
    }

    @Test("Set returns set")
    func setReturnsSet() {
        let type = ColumnType.set(rawType: "SET('x','y')", values: ["x", "y"])
        #expect(type.badgeLabel == "set")
    }

    @Test("Decimal returns number")
    func decimalReturnsNumber() {
        let type = ColumnType.decimal(rawType: "DECIMAL(10,2)")
        #expect(type.badgeLabel == "number")
    }

    @Test("Blob returns binary")
    func blobReturnsBinary() {
        let type = ColumnType.blob(rawType: "BLOB")
        #expect(type.badgeLabel == "binary")
    }

    // MARK: - Edge Cases

    @Test("Text with nil rawType returns string")
    func textNilRawTypeReturnsString() {
        let type = ColumnType.text(rawType: nil)
        #expect(type.badgeLabel == "string")
    }

    @Test("Integer with nil rawType returns number")
    func integerNilRawTypeReturnsNumber() {
        let type = ColumnType.integer(rawType: nil)
        #expect(type.badgeLabel == "number")
    }

    @Test("EnumType with nil rawType returns enum")
    func enumNilRawTypeReturnsEnum() {
        let type = ColumnType.enumType(rawType: nil, values: nil)
        #expect(type.badgeLabel == "enum")
    }

    @Test("Decimal with nil rawType returns number")
    func decimalNilRawTypeReturnsNumber() {
        let type = ColumnType.decimal(rawType: nil)
        #expect(type.badgeLabel == "number")
    }

    @Test("Non-Redis rawType on text still returns string")
    func nonRedisTextRawTypeReturnsString() {
        let type = ColumnType.text(rawType: "LONGTEXT")
        #expect(type.badgeLabel == "string")
    }

    @Test("Non-Redis rawType on integer still returns number")
    func nonRedisIntegerRawTypeReturnsNumber() {
        let type = ColumnType.integer(rawType: "BIGINT")
        #expect(type.badgeLabel == "number")
    }

    @Test("Non-Redis rawType on enum still returns enum")
    func nonRedisEnumRawTypeReturnsEnum() {
        let type = ColumnType.enumType(rawType: "ENUM(status)", values: nil)
        #expect(type.badgeLabel == "enum")
    }

    @Test("Spatial returns spatial")
    func spatialReturnsSpatial() {
        let type = ColumnType.spatial(rawType: "GEOMETRY")
        #expect(type.badgeLabel == "spatial")
    }
}
