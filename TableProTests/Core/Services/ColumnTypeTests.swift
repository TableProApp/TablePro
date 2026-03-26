//
//  ColumnTypeTests.swift
//  TableProTests
//
//  Tests for ColumnType enum/set detection, parsing, and type identification.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column Type")
struct ColumnTypeTests {
    // MARK: - isEnumType / isSetType Properties

    @Test("enumType case reports isEnumType true")
    func enumTypeIsEnumType() {
        let type = ColumnType.enumType(rawType: "ENUM('a','b')", values: ["a", "b"])
        #expect(type.isEnumType)
    }

    @Test("enumType case reports isSetType false")
    func enumTypeIsNotSetType() {
        let type = ColumnType.enumType(rawType: "ENUM('a','b')", values: ["a", "b"])
        #expect(!type.isSetType)
    }

    @Test("set case reports isSetType true")
    func setTypeIsSetType() {
        let type = ColumnType.set(rawType: "SET('x','y')", values: ["x", "y"])
        #expect(type.isSetType)
    }

    @Test("set case reports isEnumType false")
    func setTypeIsNotEnumType() {
        let type = ColumnType.set(rawType: "SET('x','y')", values: ["x", "y"])
        #expect(!type.isEnumType)
    }

    @Test("text type reports isEnumType false")
    func textIsNotEnumType() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        #expect(!type.isEnumType)
    }

    @Test("text type reports isSetType false")
    func textIsNotSetType() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        #expect(!type.isSetType)
    }

    @Test("integer type reports isEnumType false")
    func integerIsNotEnumType() {
        let type = ColumnType.integer(rawType: "INT")
        #expect(!type.isEnumType)
    }

    @Test("boolean type reports isEnumType false")
    func booleanIsNotEnumType() {
        let type = ColumnType.boolean(rawType: "TINYINT(1)")
        #expect(!type.isEnumType)
    }

    @Test("json type reports isEnumType false")
    func jsonIsNotEnumType() {
        let type = ColumnType.json(rawType: "JSON")
        #expect(!type.isEnumType)
    }

    @Test("blob type reports isSetType false")
    func blobIsNotSetType() {
        let type = ColumnType.blob(rawType: "BLOB")
        #expect(!type.isSetType)
    }

    // MARK: - enumValues Property

    @Test("enumType with values returns those values")
    func enumTypeReturnsValues() {
        let type = ColumnType.enumType(rawType: "ENUM('a','b')", values: ["a", "b"])
        #expect(type.enumValues == ["a", "b"])
    }

    @Test("set with values returns those values")
    func setTypeReturnsValues() {
        let type = ColumnType.set(rawType: "SET('x','y')", values: ["x", "y"])
        #expect(type.enumValues == ["x", "y"])
    }

    @Test("enumType with nil values returns nil")
    func enumTypeWithNilValuesReturnsNil() {
        let type = ColumnType.enumType(rawType: "ENUM", values: nil)
        #expect(type.enumValues == nil)
    }

    @Test("text type returns nil for enumValues")
    func textReturnsNilEnumValues() {
        let type = ColumnType.text(rawType: "VARCHAR(255)")
        #expect(type.enumValues == nil)
    }

    @Test("integer type returns nil for enumValues")
    func integerReturnsNilEnumValues() {
        let type = ColumnType.integer(rawType: "INT")
        #expect(type.enumValues == nil)
    }

    @Test("boolean type returns nil for enumValues")
    func booleanReturnsNilEnumValues() {
        let type = ColumnType.boolean(rawType: "BOOL")
        #expect(type.enumValues == nil)
    }

    // MARK: - parseEnumValues Static Method

    @Test("parses ENUM with multiple values")
    func parseEnumMultipleValues() {
        let result = ColumnType.parseEnumValues(from: "ENUM('a','b','c')")
        #expect(result == ["a", "b", "c"])
    }

    @Test("parses SET with multiple values")
    func parseSetMultipleValues() {
        let result = ColumnType.parseEnumValues(from: "SET('x','y')")
        #expect(result == ["x", "y"])
    }

    @Test("parses enum prefix case-insensitively")
    func parseEnumCaseInsensitive() {
        let result = ColumnType.parseEnumValues(from: "enum('Active','Inactive')")
        #expect(result == ["Active", "Inactive"])
    }

    @Test("parses values with spaces")
    func parseValuesWithSpaces() {
        let result = ColumnType.parseEnumValues(from: "ENUM('hello world','foo bar')")
        #expect(result == ["hello world", "foo bar"])
    }

    @Test("parses values with escaped quotes")
    func parseValuesWithEscapedQuotes() {
        let result = ColumnType.parseEnumValues(from: "ENUM('it\\'s','ok')")
        #expect(result == ["it's", "ok"])
    }

    @Test("returns nil for empty parentheses")
    func parseEmptyParens() {
        let result = ColumnType.parseEnumValues(from: "ENUM()")
        #expect(result == nil)
    }

    @Test("returns nil for non-enum type string")
    func parseNonEnumPrefix() {
        let result = ColumnType.parseEnumValues(from: "VARCHAR(255)")
        #expect(result == nil)
    }

    @Test("parses single value")
    func parseSingleValue() {
        let result = ColumnType.parseEnumValues(from: "ENUM('only')")
        #expect(result == ["only"])
    }

    // MARK: - Other Type Properties Are False for Enum/Set

    @Test("enumType is not JSON type")
    func enumIsNotJsonType() {
        let type = ColumnType.enumType(rawType: "ENUM('a')", values: ["a"])
        #expect(!type.isJsonType)
    }

    @Test("enumType is not date type")
    func enumIsNotDateType() {
        let type = ColumnType.enumType(rawType: "ENUM('a')", values: ["a"])
        #expect(!type.isDateType)
    }

    @Test("enumType is not boolean type")
    func enumIsNotBooleanType() {
        let type = ColumnType.enumType(rawType: "ENUM('a')", values: ["a"])
        #expect(!type.isBooleanType)
    }

    @Test("enumType is not long text")
    func enumIsNotLongText() {
        let type = ColumnType.enumType(rawType: "ENUM('a')", values: ["a"])
        #expect(!type.isLongText)
    }

    @Test("set is not JSON type")
    func setIsNotJsonType() {
        let type = ColumnType.set(rawType: "SET('a')", values: ["a"])
        #expect(!type.isJsonType)
    }

    @Test("set is not date type")
    func setIsNotDateType() {
        let type = ColumnType.set(rawType: "SET('a')", values: ["a"])
        #expect(!type.isDateType)
    }

    @Test("set is not boolean type")
    func setIsNotBooleanType() {
        let type = ColumnType.set(rawType: "SET('a')", values: ["a"])
        #expect(!type.isBooleanType)
    }

    @Test("set is not long text")
    func setIsNotLongText() {
        let type = ColumnType.set(rawType: "SET('a')", values: ["a"])
        #expect(!type.isLongText)
    }

    // MARK: - displayName and badgeLabel

    @Test("enumType displayName is Enum")
    func enumDisplayName() {
        let type = ColumnType.enumType(rawType: nil, values: nil)
        #expect(type.displayName == "Enum")
    }

    @Test("enumType badgeLabel is enum")
    func enumBadgeLabel() {
        let type = ColumnType.enumType(rawType: nil, values: nil)
        #expect(type.badgeLabel == "enum")
    }

    @Test("set displayName is Set")
    func setDisplayName() {
        let type = ColumnType.set(rawType: nil, values: nil)
        #expect(type.displayName == "Set")
    }

    @Test("set badgeLabel is set")
    func setBadgeLabel() {
        let type = ColumnType.set(rawType: nil, values: nil)
        #expect(type.badgeLabel == "set")
    }

    // MARK: - isLongText for NTEXT

    @Test("NTEXT is long text")
    func ntextIsLongText() {
        let type = ColumnType.text(rawType: "NTEXT")
        #expect(type.isLongText)
    }

    @Test("NTEXT is not very long text")
    func ntextIsNotVeryLongText() {
        let type = ColumnType.text(rawType: "NTEXT")
        #expect(!type.isVeryLongText)
    }

    // MARK: - parseClickHouseEnumValues

    @Test("parses Enum8 with values and assignments")
    func parseEnum8Values() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum8('active' = 1, 'inactive' = 2)")
        #expect(result == ["active", "inactive"])
    }

    @Test("parses Enum16 with single value")
    func parseEnum16SingleValue() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum16('only' = 1)")
        #expect(result == ["only"])
    }

    @Test("parses Enum8 with escaped quotes")
    func parseEnum8EscapedQuotes() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum8('it\\'s' = 1, 'ok' = 2)")
        #expect(result == ["it's", "ok"])
    }

    @Test("parses Enum8 with negative assignments")
    func parseEnum8NegativeAssignments() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum8('a' = -1, 'b' = 0, 'c' = 1)")
        #expect(result == ["a", "b", "c"])
    }

    @Test("parses Enum8 with spaces in values")
    func parseEnum8WithSpaces() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum8('hello world' = 1, 'foo bar' = 2)")
        #expect(result == ["hello world", "foo bar"])
    }

    @Test("returns nil for regular ENUM prefix")
    func parseClickHouseReturnsNilForRegularEnum() {
        let result = ColumnType.parseClickHouseEnumValues(from: "ENUM('a','b')")
        #expect(result == nil)
    }

    @Test("returns nil for non-enum type")
    func parseClickHouseReturnsNilForNonEnum() {
        let result = ColumnType.parseClickHouseEnumValues(from: "String")
        #expect(result == nil)
    }

    @Test("returns nil for empty Enum8")
    func parseClickHouseEmptyEnum() {
        let result = ColumnType.parseClickHouseEnumValues(from: "Enum8()")
        #expect(result == nil)
    }
}
