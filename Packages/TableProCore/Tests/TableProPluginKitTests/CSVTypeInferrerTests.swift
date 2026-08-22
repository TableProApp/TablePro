import XCTest
@testable import TableProPluginKit

final class CSVTypeInferrerTests: XCTestCase {
    func testInfersInteger() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["1", "-42", "0"]), .integer)
    }

    func testInfersRealWhenNotEveryValueIsWhole() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["1", "2.5", "-0.25"]), .real)
    }

    func testInfersBooleanFromEitherSpelling() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["true", "FALSE", "Yes", "n", "T"]), .boolean)
    }

    func testInfersDateFromInternetDateTime() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56Z"]), .date)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56+02:00"]), .date)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56-0700"]), .date)
    }

    func testInfersDateFromFractionalSeconds() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20T12:34:56.123Z"]), .date)
    }

    func testInfersDateFromCalendarDay() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20", "1999-01-01", "0001-01-01"]), .date)
    }

    func testInfersDateFromLeapDay() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2024-02-29"]), .date)
    }

    func testInfersDateFromTheLenientFormsTheFormatterAccepts() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["  2026-08-20"]), .date)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026/08/20"]), .date)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["-0001-01-01"]), .date)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2023-02-29"]), .date)
    }

    func testRejectsImpossibleCalendarDay() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-13-45"]), .text)
    }

    func testRejectsBasicFormatDate() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["20260820"]), .integer)
    }

    func testFallsBackToTextForMixedValues() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["2026-08-20", "not a date"]), .text)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["hello"]), .text)
    }

    func testEmptyValuesAreSkippedAndAnEmptyColumnIsText() {
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["", "7", ""]), .integer)
        XCTAssertEqual(CSVTypeInferrer.infer(column: ["", ""]), .text)
        XCTAssertEqual(CSVTypeInferrer.infer(column: []), .text)
    }

    func testInferColumnsHandlesRaggedRows() {
        let rows = [
            ["1", "true", "2026-08-20"],
            ["2", "no"],
            ["3", "yes", "1999-01-01", "extra"]
        ]
        XCTAssertEqual(
            CSVTypeInferrer.inferColumns(rows: rows, columnCount: 3),
            [.integer, .boolean, .date]
        )
    }

    func testOnlyTheFirstSampleSizeValuesAreRead() {
        let values = Array(repeating: "1", count: CSVTypeInferrer.sampleSize) + ["not a number"]
        XCTAssertEqual(CSVTypeInferrer.infer(column: values), .integer)
    }
}
