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
    private func text() -> KeyOrdering { KeyOrdering(orders: [.binaryText]) }

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
        let ordering = KeyOrdering(orders: [.binaryText, .numeric])

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
            columnTypes: ["id": "bigint", "name": "varchar(50)"]
        )

        XCTAssertEqual(orders, [.numeric, .binaryText])
    }

    func testUnknownColumnTypeFallsBackToBinaryText() {
        XCTAssertEqual(KeyOrdering.orders(for: ["mystery"], columnTypes: [:]), [.binaryText])
    }

    // MARK: - Stream order check

    func testNumericOnlyKeysNeedNoStreamCheck() {
        XCTAssertFalse(KeyOrdering(orders: [.numeric]).requiresStreamOrderCheck)
    }

    func testTextKeysRequireStreamCheck() {
        XCTAssertTrue(KeyOrdering(orders: [.numeric, .binaryText]).requiresStreamOrderCheck)
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
            columnTypes: ["id": numericKey ? "int" : "varchar(20)"]
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
