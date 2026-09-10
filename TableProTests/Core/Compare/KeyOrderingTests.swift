//
//  KeyOrderingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

final class KeyOrderingPolicyTests: XCTestCase {
    private func numeric() -> KeyOrdering { KeyOrdering(orders: [.numeric]) }
    private func text() -> KeyOrdering { KeyOrdering(orders: [.caseSensitiveText]) }

    func testNumericKeysOrderNumerically() {
        XCTAssertEqual(numeric().compare([.text("9")], [.text("10")]), .orderedAscending)
        XCTAssertEqual(numeric().compare([.text("10")], [.text("9")]), .orderedDescending)
    }

    func testTextKeysOrderByBytesNotByNumericValue() {
        XCTAssertEqual(
            text().compare([.text("10")], [.text("9")]), .orderedAscending,
            "a text key must sort the way a byte-ordered collation sorts, not numerically"
        )
    }

    func testTextOrderingIsCaseSensitiveByBytes() {
        XCTAssertEqual(text().compare([.text("Carol")], [.text("bob")]), .orderedAscending)
    }

    func testEqualKeysReportSame() {
        XCTAssertEqual(text().compare([.text("a"), .text("1")], [.text("a"), .text("1")]), .orderedSame)
    }

    func testOrderingIsAntisymmetric() {
        let pairs: [([PluginCellValue], [PluginCellValue])] = [
            ([.text("1")], [.text("2")]),
            ([.text("b")], [.text("a")]),
            ([.bytes(Data([1]))], [.bytes(Data([2]))])
        ]
        for (left, right) in pairs {
            XCTAssertNotEqual(text().compare(left, right), text().compare(right, left))
        }
    }

    func testCompositeKeyFallsThroughToSecondColumn() {
        let ordering = KeyOrdering(orders: [.caseSensitiveText, .numeric])

        XCTAssertEqual(
            ordering.compare([.text("a"), .text("2")], [.text("a"), .text("10")]),
            .orderedAscending
        )
    }

    // MARK: - Type classification

    func testNumericTypesAreClassifiedNumeric() {
        for type in ["int", "INT(11)", "bigint unsigned", "numeric(10,2)", "double precision", "serial"] {
            XCTAssertTrue(KeyOrdering.isNumeric(type), "\(type) should compare numerically")
        }
    }

    func testTextAndDateTypesAreNotNumeric() {
        for type in ["varchar(255)", "text", "uuid", "timestamp", "date", "bytea"] {
            XCTAssertFalse(KeyOrdering.isNumeric(type), "\(type) should not compare numerically")
        }
    }

    func testOrdersDerivedFromDeclaredColumnTypes() {
        let orders = KeyOrdering.orders(
            for: ["id", "name"],
            descriptors: [
                KeyColumnDescriptor(name: "id", dataType: "bigint"),
                KeyColumnDescriptor(name: "name", dataType: "varchar(50)")
            ]
        )

        XCTAssertEqual(orders, [.numeric, .caseSensitiveText])
    }

    func testUnknownColumnTypeFallsBackToCaseSensitiveText() {
        XCTAssertEqual(KeyOrdering.orders(for: ["mystery"], descriptors: []), [.caseSensitiveText])
    }

    // MARK: - Exact numeric ordering

    /// Going through Double collapsed every pair of integers sharing the first 53 bits, so two
    /// Snowflake ids one apart matched as the same row and the engine emitted an UPDATE that
    /// overwrote a different row.
    func testTwoBigIntegersAboveTwoToTheFiftyThreeAreNotEqual() {
        let ordering = numeric()
        let lower: [PluginCellValue] = [.text("1234567890123456789")]
        let higher: [PluginCellValue] = [.text("1234567890123456790")]

        XCTAssertEqual(ordering.compare(lower, higher), .orderedAscending)
        XCTAssertEqual(ordering.compare(higher, lower), .orderedDescending)
        XCTAssertEqual(ordering.compare(lower, lower), .orderedSame)
    }

    func testNumericOrderingIsNotLexicographic() {
        XCTAssertEqual(numeric().compare([.text("9")], [.text("10")]), .orderedAscending)
    }

    /// An unparsable numeric key used to collapse onto a shared zero, which made every one of them
    /// compare equal to every other.
    func testUnparsableNumericKeysStayDistinct() {
        XCTAssertNotEqual(numeric().compare([.text("n/a")], [.text("unknown")]), .orderedSame)
    }

    // MARK: - Collation

    func testCaseInsensitiveCollationIsDetectedPerEngine() {
        for collation in ["utf8mb4_general_ci", "NOCASE", "SQL_Latin1_General_CP1_CI_AS"] {
            XCTAssertTrue(KeyOrdering.isCaseInsensitive(collation), "\(collation) is case-insensitive")
        }
        for collation in ["utf8mb4_bin", "SQL_Latin1_General_CP1_CS_AS", "C", nil] {
            XCTAssertFalse(KeyOrdering.isCaseInsensitive(collation), "\(collation ?? "nil") is case-sensitive")
        }
    }

    /// The server's own key constraint treats these as one row, so a byte comparator reported an
    /// orphan insert for a row the target already had.
    func testCaseInsensitiveKeyMatchesRegardlessOfCase() {
        let ordering = KeyOrdering(orders: [.caseInsensitiveText])

        XCTAssertEqual(ordering.compare([.text("Alice")], [.text("ALICE")]), .orderedSame)
        XCTAssertEqual(KeyOrdering(orders: [.caseSensitiveText]).compare(
            [.text("Alice")], [.text("ALICE")]
        ), .orderedDescending)
    }

    func testCollationDecidesTheTextOrder() {
        let orders = KeyOrdering.orders(
            for: ["name", "code"],
            descriptors: [
                KeyColumnDescriptor(name: "name", dataType: "varchar(50)", collation: "utf8mb4_general_ci"),
                KeyColumnDescriptor(name: "code", dataType: "varchar(50)", collation: "utf8mb4_bin")
            ]
        )

        XCTAssertEqual(orders, [.caseInsensitiveText, .caseSensitiveText])
    }

    // MARK: - NULL keys

    func testNullComponentIsDetected() {
        XCTAssertTrue(KeyOrdering.hasNullComponent([.text("a"), .null]))
        XCTAssertFalse(KeyOrdering.hasNullComponent([.text("a"), .text("b")]))
    }
}

final class DataDiffOrderingSafetyTests: XCTestCase {
    private func row(_ id: String) -> DataRow {
        DataRow(values: ["id": .text(id), "name": .text("n")])
    }

    private func engine(numericKey: Bool) -> DataDiffEngine {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]
        return DataDiffEngine(
            options: options,
            columns: ["id", "name"],
            keyDescriptors: [
                KeyColumnDescriptor(name: "id", dataType: numericKey ? "int" : "varchar(20)")
            ]
        )
    }

    /// The case that previously produced a delete for a row present on both sides.
    func testDisagreeingCollationIsReportedInsteadOfDeletingAMatchingRow() async {
        let source = ArrayRowProvider(rows: [row("Alice"), row("bob"), row("Carol")])
        let target = ArrayRowProvider(rows: [row("Alice"), row("Carol")])

        do {
            let summary = try await engine(numericKey: false).compare(source: source, target: target)
            XCTAssertEqual(
                summary.deleteCount, 0,
                "a row present on both sides must never be reported as a delete"
            )
        } catch let error as CompareSyncError {
            guard case .streamOutOfOrder = error else {
                return XCTFail("Expected an out-of-order report, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testOutOfOrderTextStreamThrowsRatherThanMismatching() async {
        let source = ArrayRowProvider(rows: [row("Alice"), row("bob"), row("Carol")])
        let target = ArrayRowProvider(rows: [row("Alice")])

        do {
            _ = try await engine(numericKey: false).compare(source: source, target: target)
            XCTFail("Expected an out-of-order error for a case-insensitively sorted stream")
        } catch let error as CompareSyncError {
            guard case .streamOutOfOrder(let message) = error else {
                return XCTFail("Expected streamOutOfOrder, got \(error)")
            }
            XCTAssertTrue(
                message.contains("Carol"),
                "the message must name the key the read stopped at: \(message)"
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testInOrderTextStreamComparesNormally() async throws {
        let source = ArrayRowProvider(rows: [row("Alice"), row("Carol"), row("bob")])
        let target = ArrayRowProvider(rows: [row("Alice"), row("Carol")])

        let summary = try await engine(numericKey: false).compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 2)
        XCTAssertEqual(summary.insertCount, 1)
        XCTAssertEqual(summary.deleteCount, 0)
    }

    func testNumericKeysNeedNoOrderCheckAndCompareNumerically() async throws {
        let source = ArrayRowProvider(rows: [row("2"), row("9"), row("10")])
        let target = ArrayRowProvider(rows: [row("2"), row("10")])

        let summary = try await engine(numericKey: true).compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 2)
        XCTAssertEqual(summary.insertCount, 1, "9 is only on the source")
        XCTAssertEqual(summary.deleteCount, 0, "10 exists on both sides and must not be deleted")
    }

    func testRowsWithNullKeysAreSkippedNotGivenAnArbitraryOrder() async throws {
        let withNullKey = DataRow(values: ["id": .null, "name": .text("n")])
        let source = ArrayRowProvider(rows: [withNullKey, row("1"), row("2")])
        let target = ArrayRowProvider(rows: [row("1")])

        let summary = try await engine(numericKey: true).compare(source: source, target: target)

        XCTAssertEqual(summary.skippedNullKeyCount, 1)
        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.insertCount, 1, "only the non-null key rows take part")
    }
}
