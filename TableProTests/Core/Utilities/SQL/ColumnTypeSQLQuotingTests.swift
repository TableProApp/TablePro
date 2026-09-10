//
//  ColumnTypeSQLQuotingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro
import TableProPluginKit

@Suite("Column Type SQL Quoting")
struct ColumnTypeSQLQuotingTests {

    @Test("An integer column only treats a plain integer as numeric")
    func integerColumnNumericShapes() {
        let expectations: [String: Bool] = [
            "68": true, "-68": true, "0068": true,
            "+68": false, "68.5": false, "1e5": false, "0x1F": false, "68a": false, "": false
        ]
        for (value, expected) in expectations {
            #expect(
                ColumnTypeSQLQuoting.isNumericLiteral(value, for: .integer(rawType: "INT")) == expected,
                "integer column, value \(value)"
            )
        }
    }

    @Test("A decimal column accepts anything Double parses")
    func decimalColumnNumericShapes() {
        let expectations: [String: Bool] = [
            "68": true, "68.5": true, "-68.5": true, "+68": true, "1e5": true,
            "68a": false, "": false, "0x1F": false, "nan": false, "infinity": false
        ]
        for (value, expected) in expectations {
            #expect(
                ColumnTypeSQLQuoting.isNumericLiteral(value, for: .decimal(rawType: "DECIMAL")) == expected,
                "decimal column, value \(value)"
            )
        }
    }

    @Test("Non-numeric column types never treat a value as numeric")
    func nonNumericColumnTypesAreNeverNumeric() {
        let types: [ColumnType] = [
            .text(rawType: "VARCHAR"),
            .boolean(rawType: "BOOLEAN"),
            .date(rawType: "DATE"),
            .timestamp(rawType: "TIMESTAMP"),
            .datetime(rawType: "DATETIME"),
            .blob(rawType: "BLOB"),
            .json(rawType: "JSON"),
            .enumType(rawType: "ENUM", values: nil),
            .set(rawType: "SET", values: nil),
            .spatial(rawType: "GEOMETRY")
        ]
        for type in types {
            #expect(ColumnTypeSQLQuoting.isNumericLiteral("68", for: type) == false)
        }
    }

    @Test("An unknown column type keeps the legacy shape heuristic")
    func unknownColumnTypeUsesShapeHeuristic() {
        #expect(ColumnTypeSQLQuoting.isNumericLiteral("68", for: nil))
        #expect(ColumnTypeSQLQuoting.isNumericLiteral("68.5", for: nil))
        #expect(ColumnTypeSQLQuoting.isNumericLiteral("1e5", for: nil))
        #expect(ColumnTypeSQLQuoting.isNumericLiteral("68a", for: nil) == false)
    }

    @Test("Only text, enum and set count as text-like")
    func textLikeColumnTypes() {
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.text(rawType: "VARCHAR")))
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.enumType(rawType: "ENUM", values: nil)))
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.set(rawType: "SET", values: nil)))
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.integer(rawType: "INT")) == false)
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.json(rawType: "JSON")) == false)
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(nil) == false)
    }

    @Test("Empty string comparison applies to text-like and unknown types only")
    func emptyStringComparisonSupport() {
        #expect(ColumnTypeSQLQuoting.supportsEmptyStringComparison(nil))
        #expect(ColumnTypeSQLQuoting.supportsEmptyStringComparison(.text(rawType: "VARCHAR")))
        #expect(ColumnTypeSQLQuoting.supportsEmptyStringComparison(.integer(rawType: "INT")) == false)
        #expect(ColumnTypeSQLQuoting.supportsEmptyStringComparison(.date(rawType: "DATE")) == false)
    }

    @Test("Boolean synonyms map both spellings")
    func booleanSynonyms() {
        for value in ["true", "TRUE", "1", "yes", "on"] {
            #expect(ColumnTypeSQLQuoting.booleanSynonym(for: value) == .isTrue)
        }
        for value in ["false", "FALSE", "0", "no", "off"] {
            #expect(ColumnTypeSQLQuoting.booleanSynonym(for: value) == .isFalse)
        }
        #expect(ColumnTypeSQLQuoting.booleanSynonym(for: "68") == nil)
    }

    @Test("The name lookup is index aligned and keeps the first of a repeated name")
    func nameLookupAlignment() {
        let lookup = ColumnTypeSQLQuoting.lookupByName(
            columns: ["id", "code", "code"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR"), .decimal(rawType: "DECIMAL")]
        )
        #expect(lookup["id"] == .integer(rawType: "INT"))
        #expect(lookup["code"] == .text(rawType: "VARCHAR"))
    }

    @Test("The name lookup ignores columns beyond the type array")
    func nameLookupIgnoresMissingTypes() {
        let lookup = ColumnTypeSQLQuoting.lookupByName(
            columns: ["id", "code"],
            columnTypes: [.integer(rawType: "INT")]
        )
        #expect(lookup["id"] == .integer(rawType: "INT"))
        #expect(lookup["code"] == nil)
    }

    @Test("Character types are told apart from the other types the classifier files under text")
    func characterTypeDetection() {
        let character = [
            "VARCHAR(255)", "character varying", "text", "bpchar", "nvarchar2", "CLOB", "citext", "name", "String"
        ]
        for rawType in character {
            #expect(ColumnTypeSQLQuoting.isCharacterType(.text(rawType: rawType)), "\(rawType)")
        }
        for rawType in ["uuid", "inet", "tsvector", "interval", "money", "unknown", "xml"] {
            #expect(!ColumnTypeSQLQuoting.isCharacterType(.text(rawType: rawType)), "\(rawType)")
        }
        #expect(ColumnTypeSQLQuoting.isCharacterType(.text(rawType: nil)))
        #expect(!ColumnTypeSQLQuoting.isCharacterType(.text(rawType: "")))
        #expect(!ColumnTypeSQLQuoting.isCharacterType(.integer(rawType: "int")))
        #expect(!ColumnTypeSQLQuoting.isCharacterType(.enumType(rawType: "ENUM(mood)", values: nil)))
        #expect(!ColumnTypeSQLQuoting.isCharacterType(nil))
    }

    @Test("An array column is not text-like")
    func arrayIsNotTextLike() {
        let array = ColumnType.array(rawType: "text[]", element: .text(rawType: "text"))
        #expect(!ColumnTypeSQLQuoting.isKnownTextLike(array))
        #expect(!ColumnTypeSQLQuoting.supportsEmptyStringComparison(array))
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.text(rawType: "text")))
        #expect(ColumnTypeSQLQuoting.isKnownTextLike(.set(rawType: "SET", values: nil)))
    }
}
