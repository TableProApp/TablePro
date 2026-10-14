import Foundation
@testable import TableProPluginKit
import Testing

struct CSVTypeInferrerTests {
    @Test func testInfersInteger() {
        #expect(CSVTypeInferrer.infer(column: ["1", "-42", "0"]) == .integer)
    }

    @Test func testInfersRealWhenNotEveryValueIsWhole() {
        #expect(CSVTypeInferrer.infer(column: ["1", "2.5", "-0.25"]) == .real)
    }

    @Test func testInfersBooleanFromEitherSpelling() {
        #expect(CSVTypeInferrer.infer(column: ["true", "FALSE", "Yes", "n", "T"]) == .boolean)
    }

    @Test func testInfersDateFromInternetDateTime() {
        #expect(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56Z"]) == .date)
        #expect(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56+02:00"]) == .date)
        #expect(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56-0700"]) == .date)
    }

    @Test(arguments: ["2026-08-20T12:34:56.123Z", "2024-02-29"])
    func testInfersDateFromFractionalSecondsAndLeapDay(_ value: String) {
        #expect(CSVTypeInferrer.infer(column: [value]) == .date)
    }

    @Test func testInfersDateFromCalendarDay() {
        #expect(CSVTypeInferrer.infer(column: ["2026-08-20", "1999-01-01", "0001-01-01"]) == .date)
    }

    @Test func testInfersDateFromTheLenientFormsTheFormatterAccepts() {
        #expect(CSVTypeInferrer.infer(column: ["  2026-08-20"]) == .date)
        #expect(CSVTypeInferrer.infer(column: ["2026/08/20"]) == .date)
        #expect(CSVTypeInferrer.infer(column: ["-0001-01-01"]) == .date)
        #expect(CSVTypeInferrer.infer(column: ["2023-02-29"]) == .date)
    }

    @Test func testRejectsImpossibleCalendarDay() {
        #expect(CSVTypeInferrer.infer(column: ["2026-13-45"]) == .text)
    }

    @Test func testRejectsBasicFormatDate() {
        #expect(CSVTypeInferrer.infer(column: ["20260820"]) == .integer)
    }

    @Test func testFallsBackToTextForMixedValues() {
        #expect(CSVTypeInferrer.infer(column: ["2026-08-20", "not a date"]) == .text)
        #expect(CSVTypeInferrer.infer(column: ["hello"]) == .text)
    }

    @Test func testEmptyValuesAreSkippedAndAnEmptyColumnIsText() {
        #expect(CSVTypeInferrer.infer(column: ["", "7", ""]) == .integer)
        #expect(CSVTypeInferrer.infer(column: ["", ""]) == .text)
        #expect(CSVTypeInferrer.infer(column: []) == .text)
    }

    @Test func testInferColumnsHandlesRaggedRows() {
        let rows = [
            ["1", "true", "2026-08-20"],
            ["2", "no"],
            ["3", "yes", "1999-01-01", "extra"]
        ]
        #expect(CSVTypeInferrer.inferColumns(rows: rows, columnCount: 3) == [.integer, .boolean, .date])
    }

    @Test func testOnlyTheFirstSampleSizeValuesAreRead() {
        let values = Array(repeating: "1", count: CSVTypeInferrer.sampleSize) + ["not a number"]
        #expect(CSVTypeInferrer.infer(column: values) == .integer)
    }
}
