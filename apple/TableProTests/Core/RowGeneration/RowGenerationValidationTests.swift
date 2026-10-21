//
//  RowGenerationValidationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct RowGenerationValidationTests {
    private static let start = Date(timeIntervalSince1970: 1_704_067_200)
    private static let end = Date(timeIntervalSince1970: 1_735_603_200)

    private static func generator(_ kind: RowGeneratorKind, _ change: (inout RowGeneratorSettings) -> Void = { _ in }) -> RowGeneratorSettings {
        var settings = RowGeneratorSettings(kind: kind, dateStart: start, dateEnd: end)
        change(&settings)
        return settings
    }

    private static func issues(
        _ columns: [RowGenerationColumn],
        _ settings: [String: RowGeneratorSettings],
        rowCount: Int = 100,
        uniqueGroups: [[String]] = [],
        references: [RowGenerationReferenceSource] = []
    ) -> [RowGenerationIssue] {
        RowGenerationValidation.issues(
            for: RowGenerationSettings(rowCount: rowCount, seed: 1, columns: settings),
            in: RowGenerationTable(columns: columns, uniqueGroups: uniqueGroups, references: references)
        )
    }

    private static let smallint = RowGenerationColumn(
        name: "qty", typeName: "smallint", valueClass: .integer(minimum: -32_768, maximum: 32_767), isNullable: false
    )

    @Test("Settings that fit the table raise nothing")
    func validSettingsPass() {
        #expect(Self.issues([Self.smallint], ["qty": Self.generator(.integerRange)]).isEmpty)
    }

    @Test("The row count stays between one and a million")
    func rowCountBounds() {
        #expect(!Self.issues([Self.smallint], ["qty": Self.generator(.integerRange)], rowCount: 0).isEmpty)
        #expect(!Self.issues([Self.smallint], ["qty": Self.generator(.integerRange)], rowCount: 1_000_001).isEmpty)
        #expect(Self.issues([Self.smallint], ["qty": Self.generator(.integerRange)], rowCount: 1_000_000).isEmpty)
    }

    @Test("A range past what the column holds names the column's limits")
    func rangeOutsideTheType() {
        let issues = Self.issues([Self.smallint], ["qty": Self.generator(.integerRange) { $0.integerMaximum = 40_000 }])

        #expect(issues.map { $0.column } == ["qty"])
    }

    @Test("A decimal range too wide for its decimal places is refused before it can overflow")
    func decimalRangeTooWide() {
        let column = RowGenerationColumn(name: "ratio", typeName: "double", valueClass: .floatingPoint, isNullable: false)
        let settings = Self.generator(.decimalRange) {
            $0.decimalMinimum = -1_000_000_000
            $0.decimalMaximum = 1_000_000_000
            $0.decimalScale = 10
        }

        #expect(Self.issues([column], ["ratio": settings]).map { $0.column } == ["ratio"])
    }

    @Test("A sequence that would run past the column's maximum is refused")
    func sequencePastTheType() {
        let issues = Self.issues(
            [Self.smallint],
            ["qty": Self.generator(.sequence) { $0.integerMinimum = 32_700 }],
            rowCount: 100
        )
        #expect(issues.map { $0.column } == ["qty"])
    }

    @Test("A unique column needs at least as many different values as rows")
    func uniqueNeedsEnoughValues() {
        let column = RowGenerationColumn(name: "code", typeName: "text", valueClass: .text(maxLength: nil), isNullable: false, isUnique: true)

        #expect(Self.issues([column], ["code": Self.generator(.list) { $0.values = ["a", "b", "c"] }], rowCount: 3).isEmpty)
        #expect(Self.issues([column], ["code": Self.generator(.list) { $0.values = ["a", "b", "c"] }], rowCount: 4).map { $0.column } == ["code"])
        #expect(Self.issues([column], ["code": Self.generator(.email)], rowCount: 1_000_000).isEmpty)
    }

    @Test("A key over several columns needs enough combinations")
    func compositeNeedsEnoughCombinations() {
        let first = RowGenerationColumn(name: "a", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false)
        let second = RowGenerationColumn(name: "b", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false)
        let settings = [
            "a": Self.generator(.integerRange) { $0.integerMinimum = 1; $0.integerMaximum = 5 },
            "b": Self.generator(.integerRange) { $0.integerMinimum = 1; $0.integerMaximum = 4 }
        ]

        #expect(Self.issues([first, second], settings, rowCount: 20, uniqueGroups: [["a", "b"]]).isEmpty)
        #expect(Self.issues([first, second], settings, rowCount: 21, uniqueGroups: [["a", "b"]]).count == 1)
    }

    @Test("A NOT NULL foreign key into an empty table cannot be filled, and a nullable one can")
    func emptyReferencedTable() {
        let slot = RowGenerationReferenceSlot(sourceId: "fk", position: 0)
        let required = RowGenerationColumn(name: "user_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false, reference: slot)
        let optional = RowGenerationColumn(name: "user_id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: true, reference: slot)
        let empty = RowGenerationReferenceSource(id: "fk", referencedTable: "users", columns: ["user_id"], tuples: [])

        #expect(Self.issues([required], ["user_id": Self.generator(.reference)], references: [empty]).map { $0.column } == ["user_id"])
        #expect(Self.issues([optional], ["user_id": Self.generator(.reference)], references: [empty]).isEmpty)
    }

    @Test("Leaving every column to the server writes nothing, so it is refused")
    func somethingMustBeWritten() {
        let column = RowGenerationColumn(name: "id", typeName: "int", valueClass: .integer(minimum: .min, maximum: .max), isNullable: false, ownership: .assigned)

        #expect(Self.issues([column], ["id": Self.generator(.serverDefault)]).map { $0.column } == [nil])
    }

    @Test("A NOT NULL column no generator can fill is named")
    func unfillableColumn() {
        let column = RowGenerationColumn(name: "photo", typeName: "bytea", valueClass: .unsupported, isNullable: false)
        let other = RowGenerationColumn(name: "label", typeName: "text", valueClass: .text(maxLength: nil))

        let issues = Self.issues([column, other], ["photo": Self.generator(.serverDefault), "label": Self.generator(.text)])
        #expect(issues.map { $0.column } == ["photo"])
    }

    @Test("An empty list or pattern, and reversed ranges, are caught")
    func emptyAndReversedInputs() {
        let column = RowGenerationColumn(name: "c", typeName: "text", valueClass: .text(maxLength: nil))

        #expect(!Self.issues([column], ["c": Self.generator(.list) { $0.values = ["", ""] }]).isEmpty)
        #expect(!Self.issues([column], ["c": Self.generator(.pattern) { $0.pattern = "" }]).isEmpty)
        #expect(!Self.issues([column], ["c": Self.generator(.text) { $0.minLength = 9; $0.maxLength = 3 }]).isEmpty)
        #expect(!Self.issues([column], ["c": Self.generator(.date) { $0.dateStart = Self.end; $0.dateEnd = Self.start }]).isEmpty)
    }
}
