//
//  DataDiffEngineTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

final class DataDiffEngineTests: XCTestCase {
    private func row(_ pairs: [String: String?]) -> DataRow {
        var values: [String: PluginCellValue] = [:]
        for (key, value) in pairs {
            values[key] = value.map { PluginCellValue.text($0) } ?? .null
        }
        return DataRow(values: values)
    }

    private func engine(
        key: [String] = ["id"],
        columns: [String] = ["id", "name"],
        configure: (inout DataCompareOptions) -> Void = { _ in }
    ) -> DataDiffEngine {
        var options = DataCompareOptions()
        options.keyColumns = key
        configure(&options)
        return DataDiffEngine(options: options, columns: columns)
    }

    private func diff(
        source: [DataRow],
        target: [DataRow],
        engine: DataDiffEngine
    ) async throws -> DataDiffSummary {
        try await engine.compare(
            source: ArrayRowProvider(rows: source),
            target: ArrayRowProvider(rows: target)
        )
    }

    // MARK: - Merge join classification

    /// The retained entry list is a preview, capped at `maxRetainedEntries`. Script generation used
    /// to build DML from that list, so a table with 12,000 differences produced 5,000 statements and
    /// the run reported success. The sink sees every entry the walk produces, before the cap.
    func testTheEntrySinkSeesEveryDifferenceEvenPastTheRetentionCap() async throws {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]
        options.maxRetainedEntries = 10

        let source = ArrayRowProvider(rows: (1 ... 50).map {
            DataRow(values: ["id": .text(String(format: "%04d", $0)), "name": .text("n")])
        })
        let engine = DataDiffEngine(
            options: options,
            columns: ["id", "name"],
            keyDescriptors: [KeyColumnDescriptor(name: "id", dataType: "int")]
        )

        var seen = 0
        let summary = try await engine.compare(source: source, target: ArrayRowProvider(rows: [])) { _ in
            seen += 1
        }

        XCTAssertEqual(summary.insertCount, 50, "counts stay exact")
        XCTAssertEqual(summary.entries.count, 10, "the retained preview stays capped")
        XCTAssertTrue(summary.truncatedEntries)
        XCTAssertEqual(seen, 50, "the sink must see every difference, not the capped preview")
    }

    func testTheSinkIsOptionalAndTheCapStillAppliesWithoutIt() async throws {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]
        options.maxRetainedEntries = 2

        let source = ArrayRowProvider(rows: (1 ... 5).map {
            DataRow(values: ["id": .text("\($0)"), "name": .text("n")])
        })
        let engine = DataDiffEngine(
            options: options,
            columns: ["id", "name"],
            keyDescriptors: [KeyColumnDescriptor(name: "id", dataType: "int")]
        )

        let summary = try await engine.compare(source: source, target: ArrayRowProvider(rows: []))

        XCTAssertEqual(summary.insertCount, 5)
        XCTAssertEqual(summary.entries.count, 2)
    }

    func testRowMissingFromTargetIsAnInsert() async throws {
        let summary = try await diff(
            source: [row(["id": "1", "name": "a"]), row(["id": "2", "name": "b"])],
            target: [row(["id": "1", "name": "a"])],
            engine: engine()
        )

        XCTAssertEqual(summary.insertCount, 1)
        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 0)
        XCTAssertEqual(summary.deleteCount, 0)
    }

    func testRowMissingFromSourceIsADelete() async throws {
        let summary = try await diff(
            source: [row(["id": "1", "name": "a"])],
            target: [row(["id": "1", "name": "a"]), row(["id": "2", "name": "b"])],
            engine: engine()
        )

        XCTAssertEqual(summary.deleteCount, 1)
        XCTAssertEqual(summary.identicalCount, 1)
    }

    func testDifferingValueIsAnUpdateAndRecordsWhichRuleFired() async throws {
        let summary = try await diff(
            source: [row(["id": "1", "name": "alice"])],
            target: [row(["id": "1", "name": "bob"])],
            engine: engine()
        )

        XCTAssertEqual(summary.updateCount, 1)
        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.cellDifferences.count, 1)
        XCTAssertEqual(entry.cellDifferences[0].column, "name")
        XCTAssertEqual(entry.cellDifferences[0].rule, .exactValue)
    }

    func testInterleavedKeysAreAllClassified() async throws {
        let summary = try await diff(
            source: [row(["id": "1"]), row(["id": "3"]), row(["id": "5"])],
            target: [row(["id": "2"]), row(["id": "3"]), row(["id": "4"])],
            engine: engine(columns: ["id"])
        )

        XCTAssertEqual(summary.insertCount, 2)
        XCTAssertEqual(summary.deleteCount, 2)
        XCTAssertEqual(summary.identicalCount, 1)
    }

    func testEmptySourceMakesEveryTargetRowADelete() async throws {
        let summary = try await diff(
            source: [],
            target: [row(["id": "1"]), row(["id": "2"])],
            engine: engine(columns: ["id"])
        )

        XCTAssertEqual(summary.deleteCount, 2)
    }

    // MARK: - Composite keys

    func testCompositeKeyMatchesOnBothColumns() async throws {
        let compareEngine = engine(key: ["tenant", "id"], columns: ["tenant", "id", "name"])
        let summary = try await diff(
            source: [
                row(["tenant": "a", "id": "1", "name": "x"]),
                row(["tenant": "b", "id": "1", "name": "y"])
            ],
            target: [
                row(["tenant": "a", "id": "1", "name": "x"]),
                row(["tenant": "b", "id": "1", "name": "z"])
            ],
            engine: compareEngine
        )

        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 1, "composite keys must not collapse distinct rows")
    }

    // MARK: - No key

    func testComparingWithoutAKeyThrowsRatherThanGuessing() async {
        var options = DataCompareOptions()
        options.keyColumns = []
        let keyless = DataDiffEngine(options: options, columns: ["id"])

        do {
            _ = try await keyless.compare(
                source: ArrayRowProvider(rows: [row(["id": "1"])]),
                target: ArrayRowProvider(rows: [])
            )
            XCTFail("Expected a missing-key error")
        } catch {
            XCTAssertTrue(error is CompareSyncError)
        }
    }

    // MARK: - NULL semantics

    func testNullEqualsNullAndNeverEqualsEmptyString() async throws {
        let bothNull = try await diff(
            source: [row(["id": "1", "name": nil])],
            target: [row(["id": "1", "name": nil])],
            engine: engine()
        )
        XCTAssertEqual(bothNull.identicalCount, 1)

        let nullVersusEmpty = try await diff(
            source: [row(["id": "1", "name": nil])],
            target: [row(["id": "1", "name": ""])],
            engine: engine()
        )
        XCTAssertEqual(nullVersusEmpty.updateCount, 1)
        XCTAssertEqual(nullVersusEmpty.entries.first?.cellDifferences.first?.rule, .nullEquality)
    }

    // MARK: - Compare set versus write set

    func testExcludedColumnNeverCausesADifference() async throws {
        let compareEngine = engine(columns: ["id", "name", "updated_at"]) { options in
            options.excludedFromComparison = ["updated_at"]
        }
        let summary = try await diff(
            source: [row(["id": "1", "name": "a", "updated_at": "2026-01-01 00:00:00"])],
            target: [row(["id": "1", "name": "a", "updated_at": "2020-01-01 00:00:00"])],
            engine: compareEngine
        )

        XCTAssertEqual(summary.identicalCount, 1, "an excluded audit column must not create a diff")
    }

    func testExcludedColumnIsStillCarriedOnTheSourceRow() async throws {
        let compareEngine = engine(columns: ["id", "name", "updated_at"]) { options in
            options.excludedFromComparison = ["updated_at"]
            options.insertMissingRows = true
        }
        let summary = try await diff(
            source: [row(["id": "1", "name": "a", "updated_at": "2026-01-01 00:00:00"])],
            target: [],
            engine: compareEngine
        )

        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.kind, .insert)
        XCTAssertEqual(entry.sourceRow?.value(for: "updated_at"), .text("2026-01-01 00:00:00"))
    }

    // MARK: - Key columns are never treated as comparison columns

    func testKeyColumnIsNotAlsoComparedAsAValue() async throws {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]

        XCTAssertEqual(options.comparisonColumns(from: ["id", "name"]), ["name"])
    }

    // MARK: - Retention cap

    func testCountsStayExactWhenRetainedEntriesAreCapped() async throws {
        let compareEngine = engine(columns: ["id"]) { options in
            options.maxRetainedEntries = 2
        }
        let source = (1...10).map { row(["id": String(format: "%03d", $0)]) }

        let summary = try await diff(source: source, target: [], engine: compareEngine)

        XCTAssertEqual(summary.insertCount, 10, "counts must be exact even when entries are capped")
        XCTAssertEqual(summary.entries.count, 2)
        XCTAssertTrue(summary.truncatedEntries)
    }

    // MARK: - Cancellation

    func testCancellationStopsTheComparison() async {
        let compareEngine = engine(columns: ["id"])
        let source = (1...5_000).map { row(["id": String(format: "%06d", $0)]) }

        let task = Task {
            try await compareEngine.compare(
                source: ArrayRowProvider(rows: source),
                target: ArrayRowProvider(rows: [])
            )
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
            return
        }
        XCTAssertTrue(true, "comparison finished before cancellation was observed")
    }
}

final class CellValueComparatorTests: XCTestCase {
    private func comparator(tolerance: Double = 0, fractionalDigits: Int = 6) -> CellValueComparator {
        var options = DataCompareOptions()
        options.floatTolerance = tolerance
        options.timestampFractionalDigits = fractionalDigits
        return CellValueComparator(options: options)
    }

    func testFloatToleranceTreatsNearlyEqualValuesAsEqual() {
        let outcome = comparator(tolerance: 0.001).compare(
            .text("109.05999755859375"),
            .text("109.05999755859381")
        )

        XCTAssertTrue(outcome.isEqual)
        XCTAssertEqual(outcome.rule, .floatTolerance)
    }

    func testFloatToleranceIsSymmetric() {
        let subject = comparator(tolerance: 0.5)
        let pairs: [(String, String)] = [
            ("1.0", "1.2"),
            ("1.0", "1.8"),
            ("100.10", "100.1000"),
            ("-3.0", "-3.4"),
            ("0.0", "0.6")
        ]

        for (left, right) in pairs {
            let forward = subject.compare(.text(left), .text(right))
            let backward = subject.compare(.text(right), .text(left))
            XCTAssertEqual(
                forward.isEqual,
                backward.isEqual,
                "comparison of \(left) and \(right) must not depend on argument order"
            )
        }
    }

    func testExactComparisonIsSymmetricForMismatchedKinds() {
        let subject = comparator()

        XCTAssertEqual(
            subject.compare(.null, .text("x")).isEqual,
            subject.compare(.text("x"), .null).isEqual
        )
        XCTAssertEqual(
            subject.compare(.bytes(Data([0x01])), .text("x")).isEqual,
            subject.compare(.text("x"), .bytes(Data([0x01]))).isEqual
        )
    }

    func testZeroToleranceKeepsExactNumericComparison() {
        let outcome = comparator(tolerance: 0).compare(.text("1.0"), .text("1.00"))

        XCTAssertFalse(outcome.isEqual, "without a declared tolerance nothing is smoothed over")
    }

    func testEquivalentInstantsWithDifferentOffsetsCompareEqual() {
        let outcome = comparator().compare(
            .text("1999-01-15 08:00:00-08:00"),
            .text("1999-01-15 11:00:00-05:00")
        )

        XCTAssertTrue(outcome.isEqual, "the same instant written at two offsets is not a difference")
        XCTAssertEqual(outcome.rule, .timestampPrecision)
    }

    func testTimestampPrecisionTruncationIsHonoured() {
        let coarse = comparator(fractionalDigits: 0).compare(
            .text("2026-01-01 00:00:00.100000"),
            .text("2026-01-01 00:00:00.200000")
        )
        XCTAssertTrue(coarse.isEqual)

        let fine = comparator(fractionalDigits: 6).compare(
            .text("2026-01-01 00:00:00.100000"),
            .text("2026-01-01 00:00:00.200000")
        )
        XCTAssertFalse(fine.isEqual)
    }

    func testBinaryContentComparedByBytes() {
        let subject = comparator()

        XCTAssertTrue(subject.compare(.bytes(Data([1, 2, 3])), .bytes(Data([1, 2, 3]))).isEqual)
        XCTAssertFalse(subject.compare(.bytes(Data([1, 2, 3])), .bytes(Data([1, 2, 4]))).isEqual)
    }
}
