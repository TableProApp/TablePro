//
//  KeyOrderingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct KeyOrderingPolicyTests {
    private func numeric() -> KeyOrdering { KeyOrdering(orders: [.numeric]) }
    private func text() -> KeyOrdering { KeyOrdering(orders: [.caseSensitiveText]) }

    @Test
    func numericKeysOrderNumerically() {
        #expect(numeric().compare([.text("9")], [.text("10")]) == .orderedAscending)
        #expect(numeric().compare([.text("10")], [.text("9")]) == .orderedDescending)
    }

    @Test
    func textKeysOrderByBytesNotByNumericValue() {
        #expect(text().compare([.text("10")], [.text("9")]) == .orderedAscending,
            "a text key must sort the way a byte-ordered collation sorts, not numerically")
    }

    @Test
    func textOrderingIsCaseSensitiveByBytes() {
        #expect(text().compare([.text("Carol")], [.text("bob")]) == .orderedAscending)
    }

    @Test
    func equalKeysReportSame() {
        #expect(text().compare([.text("a"), .text("1")], [.text("a"), .text("1")]) == .orderedSame)
    }

    @Test
    func orderingIsAntisymmetric() {
        let pairs: [([PluginCellValue], [PluginCellValue])] = [
            ([.text("1")], [.text("2")]),
            ([.text("b")], [.text("a")]),
            ([.bytes(Data([1]))], [.bytes(Data([2]))])
        ]
        for (left, right) in pairs {
            #expect(text().compare(left, right) != text().compare(right, left))
        }
    }

    @Test
    func compositeKeyFallsThroughToSecondColumn() {
        let ordering = KeyOrdering(orders: [.caseSensitiveText, .numeric])

        #expect(ordering.compare([.text("a"), .text("2")], [.text("a"), .text("10")]) == .orderedAscending)
    }

    // MARK: - Type classification

    @Test
    func numericTypesAreClassifiedNumeric() {
        for type in ["int", "INT(11)", "bigint unsigned", "numeric(10,2)", "double precision", "serial"] {
            #expect(KeyOrdering.isNumeric(type), "\(type) should compare numerically")
        }
    }

    @Test
    func textAndDateTypesAreNotNumeric() {
        for type in ["varchar(255)", "text", "uuid", "timestamp", "date", "bytea"] {
            #expect(!KeyOrdering.isNumeric(type), "\(type) should not compare numerically")
        }
    }

    @Test
    func ordersDerivedFromDeclaredColumnTypes() {
        let orders = KeyOrdering.orders(
            for: ["id", "name"],
            descriptors: [
                KeyColumnDescriptor(name: "id", dataType: "bigint"),
                KeyColumnDescriptor(name: "name", dataType: "varchar(50)")
            ]
        )

        #expect(orders == [.numeric, .caseSensitiveText])
    }

    @Test
    func unknownColumnTypeFallsBackToCaseSensitiveText() {
        #expect(KeyOrdering.orders(for: ["mystery"], descriptors: []) == [.caseSensitiveText])
    }

    // MARK: - Exact numeric ordering

    /// Going through Double collapsed every pair of integers sharing the first 53 bits, so two
    /// Snowflake ids one apart matched as the same row and the engine emitted an UPDATE that
    /// overwrote a different row.
    @Test
    func twoBigIntegersAboveTwoToTheFiftyThreeAreNotEqual() {
        let ordering = numeric()
        let lower: [PluginCellValue] = [.text("1234567890123456789")]
        let higher: [PluginCellValue] = [.text("1234567890123456790")]

        #expect(ordering.compare(lower, higher) == .orderedAscending)
        #expect(ordering.compare(higher, lower) == .orderedDescending)
        #expect(ordering.compare(lower, lower) == .orderedSame)
    }

    @Test
    func numericOrderingIsNotLexicographic() {
        #expect(numeric().compare([.text("9")], [.text("10")]) == .orderedAscending)
    }

    /// An unparsable numeric key used to collapse onto a shared zero, which made every one of them
    /// compare equal to every other.
    @Test
    func unparsableNumericKeysStayDistinct() {
        #expect(numeric().compare([.text("n/a")], [.text("unknown")]) != .orderedSame)
    }

    // MARK: - Collation

    @Test
    func caseInsensitiveCollationIsDetectedPerEngine() {
        for collation in ["utf8mb4_general_ci", "NOCASE", "SQL_Latin1_General_CP1_CI_AS"] {
            #expect(KeyOrdering.isCaseInsensitive(collation), "\(collation) is case-insensitive")
        }
        for collation in ["utf8mb4_bin", "SQL_Latin1_General_CP1_CS_AS", "C", nil] {
            #expect(!KeyOrdering.isCaseInsensitive(collation), "\(collation ?? "nil") is case-sensitive")
        }
    }

    /// The server's own key constraint treats these as one row, so a byte comparator reported an
    /// orphan insert for a row the target already had.
    @Test
    func caseInsensitiveKeyMatchesRegardlessOfCase() {
        let ordering = KeyOrdering(orders: [.caseInsensitiveText])

        #expect(ordering.compare([.text("Alice")], [.text("ALICE")]) == .orderedSame)
        #expect(KeyOrdering(orders: [.caseSensitiveText]).compare(
            [.text("Alice")], [.text("ALICE")]
        ) == .orderedDescending)
    }

    @Test
    func collationDecidesTheTextOrder() {
        let orders = KeyOrdering.orders(
            for: ["name", "code"],
            descriptors: [
                KeyColumnDescriptor(name: "name", dataType: "varchar(50)", collation: "utf8mb4_general_ci"),
                KeyColumnDescriptor(name: "code", dataType: "varchar(50)", collation: "utf8mb4_bin")
            ]
        )

        #expect(orders == [.caseInsensitiveText, .caseSensitiveText])
    }

    // MARK: - NULL keys

    @Test
    func nullComponentIsDetected() {
        #expect(KeyOrdering.hasNullComponent([.text("a"), .null]))
        #expect(!(KeyOrdering.hasNullComponent([.text("a"), .text("b")])))
    }
}

struct DataDiffOrderingSafetyTests {
    private func row(_ id: String) -> DataRow {
        DataRow(values: ["id": .text(id), "name": .text("n")])
    }

    private func engine(numericKey: Bool) -> DataDiffEngine {
        let descriptors = [KeyColumnDescriptor(name: "id", dataType: numericKey ? "int" : "varchar(20)")]
        return DataDiffEngine(
            options: DataCompareOptions(),
            shape: DataComparisonShape(
                keyColumns: ["id"],
                keyOrders: KeyOrdering.orders(for: ["id"], descriptors: descriptors),
                comparedColumns: ["name"]
            )
        )
    }

    /// The case that previously produced a delete for a row present on both sides.
    @Test
    func disagreeingCollationIsReportedInsteadOfDeletingAMatchingRow() async {
        let source = ArrayRowProvider(rows: [row("Alice"), row("bob"), row("Carol")])
        let target = ArrayRowProvider(rows: [row("Alice"), row("Carol")])

        do {
            let summary = try await engine(numericKey: false).compare(source: source, target: target)
            #expect(summary.deleteCount == 0,
                "a row present on both sides must never be reported as a delete")
        } catch let error as CompareSyncError {
            guard case .streamOutOfOrder = error else {
                Issue.record("Expected an out-of-order report, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func outOfOrderTextStreamThrowsRatherThanMismatching() async {
        let source = ArrayRowProvider(rows: [row("Alice"), row("bob"), row("Carol")])
        let target = ArrayRowProvider(rows: [row("Alice")])

        do {
            _ = try await engine(numericKey: false).compare(source: source, target: target)
            Issue.record("Expected an out-of-order error for a case-insensitively sorted stream")
        } catch let error as CompareSyncError {
            guard case .streamOutOfOrder(let message) = error else {
                Issue.record("Expected streamOutOfOrder, got \(error)")
                return
            }
            #expect(message.contains("Carol"),
                "the message must name the key the read stopped at: \(message)")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func inOrderTextStreamComparesNormally() async throws {
        let source = ArrayRowProvider(rows: [row("Alice"), row("Carol"), row("bob")])
        let target = ArrayRowProvider(rows: [row("Alice"), row("Carol")])

        let summary = try await engine(numericKey: false).compare(source: source, target: target)

        #expect(summary.identicalCount == 2)
        #expect(summary.insertCount == 1)
        #expect(summary.deleteCount == 0)
    }

    @Test
    func numericKeysNeedNoOrderCheckAndCompareNumerically() async throws {
        let source = ArrayRowProvider(rows: [row("2"), row("9"), row("10")])
        let target = ArrayRowProvider(rows: [row("2"), row("10")])

        let summary = try await engine(numericKey: true).compare(source: source, target: target)

        #expect(summary.identicalCount == 2)
        #expect(summary.insertCount == 1, "9 is only on the source")
        #expect(summary.deleteCount == 0, "10 exists on both sides and must not be deleted")
    }

    @Test
    func rowsWithNullKeysAreSkippedNotGivenAnArbitraryOrder() async throws {
        let withNullKey = DataRow(values: ["id": .null, "name": .text("n")])
        let source = ArrayRowProvider(rows: [withNullKey, row("1"), row("2")])
        let target = ArrayRowProvider(rows: [row("1")])

        let summary = try await engine(numericKey: true).compare(source: source, target: target)

        #expect(summary.skippedNullKeyCount == 1)
        #expect(summary.identicalCount == 1)
        #expect(summary.insertCount == 1, "only the non-null key rows take part")
    }
}
