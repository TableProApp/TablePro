//
//  DataDiffEngineTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

private func diffRow(_ pairs: [String: String?]) -> DataRow {
    var values: [String: PluginCellValue] = [:]
    for (key, value) in pairs {
        values[key] = value.map { PluginCellValue.text($0) } ?? .null
    }
    return DataRow(values: values)
}

private func diffIdRow(_ id: Int, name: String = "n") -> DataRow {
    DataRow(values: ["id": .text(String(id)), "name": .text(name)])
}

private func makeDiffEngine(
    key: [String] = ["id"],
    orders: [KeyOrdering.ColumnOrder] = [.numeric],
    compared: [String] = ["name"],
    valueKinds: [String: ValueComparisonKind] = [:],
    digest: [String] = ["id", "name"],
    defersOneSidedRows: Bool = false,
    configure: (inout DataCompareOptions) -> Void = { _ in }
) -> DataDiffEngine {
    var options = DataCompareOptions()
    configure(&options)
    return DataDiffEngine(
        options: options,
        shape: DataComparisonShape(
            keyColumns: key,
            keyOrders: orders,
            comparedColumns: compared,
            valueKinds: valueKinds,
            digestColumns: digest,
            defersOneSidedRows: defersOneSidedRows
        )
    )
}

private func runDiff(
    source: [DataRow],
    target: [DataRow],
    engine: DataDiffEngine,
    resolver: (any OneSidedRowResolving)? = nil
) async throws -> DataDiffSummary {
    try await engine.compare(
        source: ArrayRowProvider(rows: source),
        target: ArrayRowProvider(rows: target),
        resolver: resolver
    )
}

/// Answers a key lookup out of two in-memory tables, which is what a filtered comparison asks the
/// two connections for when a key is only on one side of the walk.
private final class ScriptedKeyResolver: OneSidedRowResolving, @unchecked Sendable {
    struct Call: Equatable {
        let keys: [[PluginCellValue]]
        let side: ComparisonSide
    }

    private let sourceRows: [DataRow]
    private let targetRows: [DataRow]
    private(set) var calls: [Call] = []

    init(sourceRows: [DataRow] = [], targetRows: [DataRow] = []) {
        self.sourceRows = sourceRows
        self.targetRows = targetRows
    }

    func rows(matching keys: [[PluginCellValue]], on side: ComparisonSide) async throws -> [DataRow] {
        calls.append(Call(keys: keys, side: side))
        let wanted = Set(keys)
        let table = side == .source ? sourceRows : targetRows
        return table.filter { wanted.contains([$0.value(for: "id")]) }
    }
}

final class DataDiffEngineTests: XCTestCase {
    // MARK: - Merge join classification

    /// The retained entry list is a preview, capped at `maxRetainedEntries`. Script generation used
    /// to build DML from that list, so a table with 12,000 differences produced 5,000 statements and
    /// the run reported success. The sink sees every entry the walk produces, before the cap.
    func testTheEntrySinkSeesEveryDifferenceEvenPastTheRetentionCap() async throws {
        let engine = makeDiffEngine { $0.maxRetainedEntries = 10 }
        var seen = 0

        let summary = try await engine.compare(
            source: ArrayRowProvider(rows: (1 ... 50).map { diffIdRow($0) }),
            target: ArrayRowProvider(rows: [])
        ) { _ in
            seen += 1
        }

        XCTAssertEqual(summary.insertCount, 50, "counts stay exact")
        XCTAssertEqual(summary.entries.count, 10, "the retained preview stays capped")
        XCTAssertTrue(summary.truncatedEntries)
        XCTAssertEqual(seen, 50, "the sink must see every difference, not the capped preview")
    }

    func testTheSinkIsOptionalAndTheCapStillAppliesWithoutIt() async throws {
        let summary = try await runDiff(
            source: (1 ... 5).map { diffIdRow($0) },
            target: [],
            engine: makeDiffEngine { $0.maxRetainedEntries = 2 }
        )

        XCTAssertEqual(summary.insertCount, 5)
        XCTAssertEqual(summary.entries.count, 2)
        XCTAssertTrue(summary.truncatedEntries)
    }

    func testRowMissingFromTargetIsAnInsert() async throws {
        let summary = try await runDiff(
            source: [diffIdRow(1, name: "a"), diffIdRow(2, name: "b")],
            target: [diffIdRow(1, name: "a")],
            engine: makeDiffEngine()
        )

        XCTAssertEqual(summary.insertCount, 1)
        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 0)
        XCTAssertEqual(summary.deleteCount, 0)
    }

    func testRowMissingFromSourceIsADelete() async throws {
        let summary = try await runDiff(
            source: [diffIdRow(1, name: "a")],
            target: [diffIdRow(1, name: "a"), diffIdRow(2, name: "b")],
            engine: makeDiffEngine()
        )

        XCTAssertEqual(summary.deleteCount, 1)
        XCTAssertEqual(summary.identicalCount, 1)
    }

    func testDifferingValueIsAnUpdateAndRecordsWhichRuleFired() async throws {
        let summary = try await runDiff(
            source: [diffIdRow(1, name: "alice")],
            target: [diffIdRow(1, name: "bob")],
            engine: makeDiffEngine()
        )

        XCTAssertEqual(summary.updateCount, 1)
        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.cellDifferences.count, 1)
        XCTAssertEqual(entry.cellDifferences[0].column, "name")
        XCTAssertEqual(entry.cellDifferences[0].rule, .exactValue)
        XCTAssertEqual(entry.cellDifferences[0].sourceValue, .text("alice"))
        XCTAssertEqual(entry.cellDifferences[0].targetValue, .text("bob"))
    }

    func testInterleavedKeysAreAllClassified() async throws {
        let summary = try await runDiff(
            source: [diffIdRow(1), diffIdRow(3), diffIdRow(5)],
            target: [diffIdRow(2), diffIdRow(3), diffIdRow(4)],
            engine: makeDiffEngine(compared: [])
        )

        XCTAssertEqual(summary.insertCount, 2)
        XCTAssertEqual(summary.deleteCount, 2)
        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.comparedKeyCount, 5, "five distinct keys took part")
        XCTAssertFalse(summary.stoppedAtRowLimit)
    }

    func testEmptySourceMakesEveryTargetRowADelete() async throws {
        let summary = try await runDiff(
            source: [],
            target: [diffIdRow(1), diffIdRow(2)],
            engine: makeDiffEngine(compared: [])
        )

        XCTAssertEqual(summary.deleteCount, 2)
    }

    // MARK: - Composite keys

    func testCompositeKeyMatchesOnBothColumns() async throws {
        let engine = makeDiffEngine(
            key: ["tenant", "id"],
            orders: [.caseSensitiveText, .numeric],
            digest: ["tenant", "id", "name"]
        )
        let summary = try await runDiff(
            source: [
                diffRow(["tenant": "a", "id": "1", "name": "x"]),
                diffRow(["tenant": "b", "id": "1", "name": "y"])
            ],
            target: [
                diffRow(["tenant": "a", "id": "1", "name": "x"]),
                diffRow(["tenant": "b", "id": "1", "name": "z"])
            ],
            engine: engine
        )

        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 1, "composite keys must not collapse distinct rows")
    }

    // MARK: - No key

    func testComparingWithoutAKeyThrowsRatherThanGuessing() async {
        let keyless = makeDiffEngine(key: [], orders: [])

        do {
            _ = try await runDiff(source: [diffIdRow(1)], target: [], engine: keyless)
            XCTFail("Expected a missing-key error")
        } catch let error as CompareSyncError {
            guard case .noComparisonKey = error else {
                return XCTFail("Expected noComparisonKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Duplicate keys

    func testADuplicateKeyOnTheSourceThrows() async {
        await expectDuplicateKey(
            source: [diffIdRow(42, name: "a"), diffIdRow(42, name: "b")],
            target: [diffIdRow(42, name: "a")],
            engine: makeDiffEngine(),
            naming: "42"
        )
    }

    func testADuplicateKeyOnTheTargetThrows() async {
        await expectDuplicateKey(
            source: [diffIdRow(42, name: "a")],
            target: [diffIdRow(42, name: "a"), diffIdRow(42, name: "b")],
            engine: makeDiffEngine(),
            naming: "42"
        )
    }

    /// The server treats the two spellings as one number, so the key identifies two rows.
    func testTwoSpellingsOfOneNumberAreADuplicateKey() async {
        await expectDuplicateKey(
            source: [diffRow(["id": "1", "name": "a"]), diffRow(["id": "1.0", "name": "b"])],
            target: [],
            engine: makeDiffEngine(),
            naming: "1.0"
        )
    }

    func testTwoCasingsOfOneTextKeyAreADuplicateUnderACaseInsensitiveOrder() async {
        await expectDuplicateKey(
            source: [diffRow(["id": "ALICE", "name": "a"]), diffRow(["id": "alice", "name": "b"])],
            target: [],
            engine: makeDiffEngine(orders: [.caseInsensitiveText]),
            naming: "alice"
        )
    }

    // MARK: - Key ordering inside a matched pair

    func testACaseOnlyKeyDifferenceUnderACaseInsensitiveOrderIsAnUpdateOnTheKey() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "alice", "name": "n"])],
            target: [diffRow(["id": "ALICE", "name": "n"])],
            engine: makeDiffEngine(orders: [.caseInsensitiveText])
        )

        XCTAssertEqual(summary.updateCount, 1)
        XCTAssertEqual(summary.insertCount, 0, "the server matched the two rows, so nothing is missing")
        XCTAssertEqual(summary.deleteCount, 0)
        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.kind, .update)
        XCTAssertTrue(entry.differs(in: "id"), "the key column itself is what differs")
        XCTAssertFalse(entry.differs(in: "name"))
        let difference = try XCTUnwrap(entry.cellDifferences.first { $0.column == "id" })
        XCTAssertEqual(difference.sourceValue, .text("alice"))
        XCTAssertEqual(difference.targetValue, .text("ALICE"))
    }

    func testACaseSensitiveOrderKeepsTwoCasingsApartAsTwoRows() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "ALICE", "name": "n"])],
            target: [diffRow(["id": "alice", "name": "n"])],
            engine: makeDiffEngine(orders: [.caseSensitiveText])
        )

        XCTAssertEqual(summary.insertCount, 1)
        XCTAssertEqual(summary.deleteCount, 1)
        XCTAssertEqual(summary.updateCount, 0)
    }

    func testTwoSpellingsOfOneNumericKeyMatchWithNoKeyDifference() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "1.0", "name": "n"])],
            target: [diffRow(["id": "1", "name": "n"])],
            engine: makeDiffEngine()
        )

        XCTAssertEqual(summary.identicalCount, 1, "1.0 and 1 are one key under a numeric order")
        XCTAssertEqual(summary.updateCount, 0)
        XCTAssertEqual(summary.insertCount, 0)
        XCTAssertEqual(summary.deleteCount, 0)
    }

    // MARK: - NULL semantics

    func testNullEqualsNullAndNeverEqualsEmptyString() async throws {
        let bothNull = try await runDiff(
            source: [diffRow(["id": "1", "name": nil])],
            target: [diffRow(["id": "1", "name": nil])],
            engine: makeDiffEngine()
        )
        XCTAssertEqual(bothNull.identicalCount, 1)

        let nullVersusEmpty = try await runDiff(
            source: [diffRow(["id": "1", "name": nil])],
            target: [diffRow(["id": "1", "name": ""])],
            engine: makeDiffEngine()
        )
        XCTAssertEqual(nullVersusEmpty.updateCount, 1)
        XCTAssertEqual(nullVersusEmpty.entries.first?.cellDifferences.first?.rule, .nullEquality)
    }

    // MARK: - Compared set

    func testAColumnOutsideTheComparedSetNeverCausesADifference() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "1", "name": "a", "updated_at": "2026-01-01 00:00:00"])],
            target: [diffRow(["id": "1", "name": "a", "updated_at": "2020-01-01 00:00:00"])],
            engine: makeDiffEngine(digest: ["id", "name", "updated_at"])
        )

        XCTAssertEqual(summary.identicalCount, 1, "an excluded audit column must not create a diff")
    }

    func testAnExcludedColumnIsStillCarriedOnTheSourceRow() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "1", "name": "a", "updated_at": "2026-01-01 00:00:00"])],
            target: [],
            engine: makeDiffEngine(digest: ["id", "name", "updated_at"])
        )

        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.kind, .insert)
        XCTAssertEqual(entry.sourceRow?.value(for: "updated_at"), .text("2026-01-01 00:00:00"))
        XCTAssertNil(entry.targetRow)
    }

    // MARK: - Identical rows

    func testIdenticalRowsAreRetainedApartFromDifferencesUpToTheirOwnCap() async throws {
        var source = (1 ... 5).map { diffIdRow($0, name: "same") }
        var target = (1 ... 5).map { diffIdRow($0, name: "same") }
        source.append(diffIdRow(6, name: "changed"))
        target.append(diffIdRow(6, name: "original"))

        let summary = try await runDiff(
            source: source,
            target: target,
            engine: makeDiffEngine { $0.maxRetainedIdenticalEntries = 3 }
        )

        XCTAssertEqual(summary.identicalCount, 5, "matches are still counted exactly")
        XCTAssertEqual(summary.identicalEntries.count, 3, "the identical preview has its own cap")
        XCTAssertEqual(summary.identicalEntries.map(\.keyIdentity), ["1", "2", "3"])
        XCTAssertTrue(summary.identicalEntries.allSatisfy { $0.kind == .identical })
        XCTAssertEqual(summary.entries.map(\.kind), [.update], "an identical row is never a difference entry")
        XCTAssertFalse(summary.truncatedEntries, "identical rows never truncate the difference preview")
    }

    func testIdenticalRowsAreStillCountedWhenNoneAreRetained() async throws {
        let summary = try await runDiff(
            source: (1 ... 4).map { diffIdRow($0) },
            target: (1 ... 4).map { diffIdRow($0) },
            engine: makeDiffEngine { $0.maxRetainedIdenticalEntries = 0 }
        )

        XCTAssertEqual(summary.identicalCount, 4)
        XCTAssertTrue(summary.identicalEntries.isEmpty)
        XCTAssertTrue(summary.entries.isEmpty)
    }

    // MARK: - Value kinds

    func testAToleranceAppliesOnlyToAColumnDeclaredNumeric() async throws {
        let engine = makeDiffEngine(
            compared: ["price", "code"],
            valueKinds: ["price": .numeric],
            digest: ["id", "price", "code"]
        ) { $0.floatTolerance = 0.01 }

        let summary = try await runDiff(
            source: [diffRow(["id": "1", "price": "1.000", "code": "1.000"])],
            target: [diffRow(["id": "1", "price": "1.004", "code": "1.004"])],
            engine: engine
        )

        XCTAssertEqual(summary.updateCount, 1)
        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertFalse(entry.differs(in: "price"), "a numeric column inside the tolerance is equal")
        XCTAssertTrue(entry.differs(in: "code"), "an untyped column stays an exact comparison")
        XCTAssertEqual(entry.cellDifferences.first { $0.column == "code" }?.rule, .exactValue)
    }

    func testValueKindsAreFoundForAColumnWrittenInAnotherCase() async throws {
        let engine = makeDiffEngine(
            compared: ["Price"],
            valueKinds: ["price": .numeric],
            digest: ["id", "Price"]
        ) { $0.floatTolerance = 0.5 }

        let summary = try await runDiff(
            source: [diffRow(["id": "1", "Price": "10.0"])],
            target: [diffRow(["id": "1", "Price": "10.4"])],
            engine: engine
        )

        XCTAssertEqual(summary.identicalCount, 1)
    }

    func testATemporalColumnComparesInstantsRatherThanText() async throws {
        let engine = makeDiffEngine(
            compared: ["created_at"],
            valueKinds: ["created_at": .temporal],
            digest: ["id", "created_at"]
        )

        let summary = try await runDiff(
            source: [diffRow(["id": "1", "created_at": "1999-01-15 08:00:00-08:00"])],
            target: [diffRow(["id": "1", "created_at": "1999-01-15 11:00:00-05:00"])],
            engine: engine
        )

        XCTAssertEqual(summary.identicalCount, 1, "the same instant at two offsets is not a difference")
    }

    /// A driver that reports no type for a column leaves nothing to decide on, so both rules stay
    /// available there rather than every timestamp spelling reading as a difference.
    func testAnUndeclaredColumnStillReconcilesTwoSpellingsOfOneInstant() async throws {
        let summary = try await runDiff(
            source: [diffRow(["id": "1", "created_at": "1999-01-15 08:00:00-08:00"])],
            target: [diffRow(["id": "1", "created_at": "1999-01-15 11:00:00-05:00"])],
            engine: makeDiffEngine(compared: ["created_at"], digest: ["id", "created_at"])
        )

        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 0)
    }

    // MARK: - Cancellation

    func testACancelledComparisonStopsInsteadOfReturningASummary() async {
        let task = Task { () async throws -> DataDiffSummary in
            withUnsafeCurrentTask { $0?.cancel() }
            let engine = makeDiffEngine()
            return try await engine.compare(
                source: ArrayRowProvider(rows: (1 ... 100).map { diffIdRow($0) }),
                target: ArrayRowProvider(rows: [])
            )
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled comparison must not return a summary")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }
    }

    // MARK: - Helpers

    private func expectDuplicateKey(
        source: [DataRow],
        target: [DataRow],
        engine: DataDiffEngine,
        naming key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await runDiff(source: source, target: target, engine: engine)
            XCTFail("Expected a duplicate key error", file: file, line: line)
        } catch let error as CompareSyncError {
            guard case .duplicateKey(let message) = error else {
                return XCTFail("Expected duplicateKey, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                message.contains(key),
                "the message must name the key that matched twice: \(message)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

final class DataDiffDigestTests: XCTestCase {
    private func engine() -> DataDiffEngine {
        makeDiffEngine(digest: ["id", "name"])
    }

    private var baseSource: [DataRow] {
        [diffIdRow(1, name: "a"), diffIdRow(2, name: "b"), diffIdRow(3, name: "c")]
    }

    private var baseTarget: [DataRow] {
        [diffIdRow(1, name: "a"), diffIdRow(2, name: "x"), diffIdRow(4, name: "d")]
    }

    func testTwoWalksOverTheSameRowsProduceTheSameDigest() async throws {
        let first = try await runDiff(source: baseSource, target: baseTarget, engine: engine())
        let second = try await runDiff(source: baseSource, target: baseTarget, engine: engine())

        XCTAssertEqual(first.differenceDigest, second.differenceDigest)
        XCTAssertEqual(first.updateCount, 1)
        XCTAssertEqual(first.insertCount, 1)
        XCTAssertEqual(first.deleteCount, 1)
    }

    func testChangingOneWrittenValueChangesTheDigest() async throws {
        let base = try await runDiff(source: baseSource, target: baseTarget, engine: engine())

        var changedUpdate = baseSource
        changedUpdate[1] = diffIdRow(2, name: "b2")
        let afterUpdateChange = try await runDiff(source: changedUpdate, target: baseTarget, engine: engine())

        var changedInsert = baseSource
        changedInsert[2] = diffIdRow(3, name: "c2")
        let afterInsertChange = try await runDiff(source: changedInsert, target: baseTarget, engine: engine())

        XCTAssertNotEqual(base.differenceDigest, afterUpdateChange.differenceDigest)
        XCTAssertNotEqual(base.differenceDigest, afterInsertChange.differenceDigest)
        XCTAssertNotEqual(afterUpdateChange.differenceDigest, afterInsertChange.differenceDigest)
    }

    func testAWalkWithNoDifferencesHasItsOwnDigest() async throws {
        let matching = try await runDiff(source: baseSource, target: baseSource, engine: engine())
        let differing = try await runDiff(source: baseSource, target: baseTarget, engine: engine())

        XCTAssertNotEqual(matching.differenceDigest, differing.differenceDigest)
    }

    func testIdenticalRowsDoNotAffectTheDigest() async throws {
        let base = try await runDiff(source: baseSource, target: baseTarget, engine: engine())

        let withExtraMatches = try await runDiff(
            source: [diffIdRow(0, name: "z")] + baseSource + [diffIdRow(9, name: "y")],
            target: [diffIdRow(0, name: "z")] + baseTarget + [diffIdRow(9, name: "y")],
            engine: engine()
        )

        var renamedSource = baseSource
        var renamedTarget = baseTarget
        renamedSource[0] = diffIdRow(1, name: "q")
        renamedTarget[0] = diffIdRow(1, name: "q")
        let withRenamedMatch = try await runDiff(source: renamedSource, target: renamedTarget, engine: engine())

        XCTAssertEqual(withExtraMatches.identicalCount, 3, "the extra rows really were walked")
        XCTAssertEqual(base.differenceDigest, withExtraMatches.differenceDigest)
        XCTAssertEqual(base.differenceDigest, withRenamedMatch.differenceDigest)
    }

    /// The digest covers every column a statement writes, so a column left out of the comparison is
    /// still part of what a script would carry across.
    func testTheDigestCoversAColumnExcludedFromTheComparison() async throws {
        let plan = DataComparePlan(
            table: "users",
            schema: nil,
            columns: [
                CompareColumn(name: "id", sourceType: "int"),
                CompareColumn(name: "name", sourceType: "varchar(40)"),
                CompareColumn(name: "updated_at", sourceType: "varchar(40)")
            ],
            scope: DataTableScope(keyColumns: ["id"], excludedColumns: ["updated_at"]),
            isEnabled: true
        )
        let planEngine = DataDiffEngine(options: DataCompareOptions(), shape: plan.comparisonShape)
        let target = [diffRow(["id": "1", "name": "old", "updated_at": "2020-01-01 00:00:00"])]

        let first = try await runDiff(
            source: [diffRow(["id": "1", "name": "new", "updated_at": "2026-01-01 00:00:00"])],
            target: target,
            engine: planEngine
        )
        let second = try await runDiff(
            source: [diffRow(["id": "1", "name": "new", "updated_at": "2026-02-02 00:00:00"])],
            target: target,
            engine: planEngine
        )

        XCTAssertEqual(plan.comparedColumns, ["name"], "the key and the excluded column stay out")
        XCTAssertEqual(first.updateCount, 1)
        XCTAssertNotEqual(first.differenceDigest, second.differenceDigest)
    }

    func testAPlanComparesNeitherItsKeyNorAnExcludedColumn() async throws {
        let plan = DataComparePlan(
            table: "users",
            schema: nil,
            columns: [
                CompareColumn(name: "id", sourceType: "int"),
                CompareColumn(name: "name", sourceType: "varchar(40)"),
                CompareColumn(name: "updated_at", sourceType: "varchar(40)")
            ],
            scope: DataTableScope(keyColumns: ["id"], excludedColumns: ["updated_at"]),
            isEnabled: true
        )

        let summary = try await runDiff(
            source: [diffRow(["id": "1", "name": "a", "updated_at": "2026-01-01 00:00:00"])],
            target: [diffRow(["id": "1", "name": "a", "updated_at": "2020-01-01 00:00:00"])],
            engine: DataDiffEngine(options: DataCompareOptions(), shape: plan.comparisonShape)
        )

        XCTAssertEqual(plan.comparisonShape.comparedColumns, ["name"])
        XCTAssertEqual(plan.comparisonShape.digestColumns, ["id", "name", "updated_at"])
        XCTAssertEqual(summary.identicalCount, 1)
    }
}

final class DataDiffRowLimitTests: XCTestCase {
    func testTheWalkStopsAtTheRowLimitWithoutInventingDifferences() async throws {
        let engine = makeDiffEngine()
        let source = ArrayRowProvider(rows: [1, 2, 3, 4].map { diffIdRow($0) }, rowLimit: 3)
        let target = ArrayRowProvider(rows: [1, 2, 3, 5, 6].map { diffIdRow($0) }, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 3)
        XCTAssertEqual(summary.insertCount, 0, "key 4 was never read on either side")
        XCTAssertEqual(summary.deleteCount, 0, "keys 5 and 6 were never read on the source")
        XCTAssertTrue(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.comparedKeyCount, 3)
    }

    /// The source's LIMIT cut it short, so the target's later keys are unread, not missing.
    func testASourceCappedByItsLimitDoesNotTurnLaterTargetKeysIntoDeletes() async throws {
        let engine = makeDiffEngine()
        let sourceRows = [diffRow(["id": nil, "name": "n"])] + [1, 2, 3].map { diffIdRow($0) }
        let source = ArrayRowProvider(rows: sourceRows, rowLimit: 3)
        let target = ArrayRowProvider(rows: [1, 2, 3, 4].map { diffIdRow($0) }, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 2)
        XCTAssertEqual(summary.deleteCount, 0)
        XCTAssertEqual(summary.skippedNullKeyCount, 1)
        XCTAssertTrue(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.comparedKeyCount, 2)
    }

    func testATargetCappedByItsLimitDoesNotTurnLaterSourceKeysIntoInserts() async throws {
        let engine = makeDiffEngine()
        let targetRows = [diffRow(["id": nil, "name": "n"])] + [1, 2, 3].map { diffIdRow($0) }
        let source = ArrayRowProvider(rows: [1, 2, 3, 4].map { diffIdRow($0) }, rowLimit: 3)
        let target = ArrayRowProvider(rows: targetRows, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 2)
        XCTAssertEqual(summary.insertCount, 0)
        XCTAssertTrue(summary.stoppedAtRowLimit)
    }

    /// A side that ran out before its limit really is exhausted, so the other side's keys are
    /// differences rather than unread rows.
    func testASideThatEndsShortOfItsLimitStillProducesDifferences() async throws {
        let engine = makeDiffEngine()
        let source = ArrayRowProvider(rows: [diffIdRow(1), diffIdRow(2)], rowLimit: 10)
        let target = ArrayRowProvider(rows: [diffIdRow(1)], rowLimit: 10)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.insertCount, 1)
        XCTAssertFalse(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.comparedKeyCount, 2)
        XCTAssertNil(summary.resumeKey, "nothing was cut short, so there is nothing to resume from")
    }

    /// The limit is a cap on each side's read, not on the merged walk. Counting merged positions
    /// against it stopped inside the region both sides had already been read past: with interleaved
    /// keys the walk quit after three positions and threw away the delete on key 4 and the insert on
    /// key 5, both of which were sitting in rows already fetched.
    func testEveryKeyBothSidesWereReadPastIsClassifiedUnderALimit() async throws {
        let engine = makeDiffEngine(compared: [])
        let source = ArrayRowProvider(rows: [1, 3, 5, 7].map { diffIdRow($0) }, rowLimit: 3)
        let target = ArrayRowProvider(rows: [2, 4, 6, 8].map { diffIdRow($0) }, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.insertCount, 3, "keys 1, 3 and 5 were read on the source")
        XCTAssertEqual(summary.deleteCount, 2, "keys 2 and 4 were read on the target")
        XCTAssertEqual(summary.comparedKeyCount, 5)
        XCTAssertTrue(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.resumeKey, [.text("5")])
    }

    /// The boundary is the lower of the two sides' last read keys, because past it one side has
    /// nothing to be compared against.
    func testTheResumeKeyIsTheLowerOfTheTwoSidesLastReadKey() async throws {
        let engine = makeDiffEngine(compared: [])
        let source = ArrayRowProvider(rows: [1, 2, 5, 6, 9].map { diffIdRow($0) }, rowLimit: 3)
        let target = ArrayRowProvider(rows: [1, 3, 4, 5, 7, 8].map { diffIdRow($0) }, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.resumeKey, [.text("4")], "the target's third key is the lower ceiling")
        XCTAssertTrue(summary.stoppedAtRowLimit)
    }

    func testTheResumeKeyIsTheCappedSidesLastKeyWhenOnlyOneSideCaps() async throws {
        let engine = makeDiffEngine(compared: [])
        let source = ArrayRowProvider(rows: [1, 2, 3, 4].map { diffIdRow($0) }, rowLimit: 2)
        let target = ArrayRowProvider(rows: [1, 2, 3, 4].map { diffIdRow($0) })

        let summary = try await engine.compare(source: source, target: target)

        XCTAssertEqual(summary.identicalCount, 2)
        XCTAssertTrue(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.resumeKey, [.text("2")])
    }

    func testAFilteredComparisonUnderALimitStillReportsWhereItStopped() async throws {
        let resolver = ScriptedKeyResolver(
            sourceRows: [1, 3, 5].map { diffIdRow($0) },
            targetRows: [2, 4, 6].map { diffIdRow($0) }
        )
        let engine = makeDiffEngine(compared: [], defersOneSidedRows: true)
        let source = ArrayRowProvider(rows: [1, 3, 5, 7].map { diffIdRow($0) }, rowLimit: 3)
        let target = ArrayRowProvider(rows: [2, 4, 6, 8].map { diffIdRow($0) }, rowLimit: 3)

        let summary = try await engine.compare(source: source, target: target, resolver: resolver)

        XCTAssertTrue(summary.stoppedAtRowLimit)
        XCTAssertEqual(summary.resumeKey, [.text("5")], "a deferred key still moves the boundary")
    }
}

final class DataDiffFilteredComparisonTests: XCTestCase {
    private struct FilteredRun {
        let summary: DataDiffSummary
        let resolver: ScriptedKeyResolver
        let sinkEntries: [RowDiffEntry]
    }

    private func runFiltered() async throws -> FilteredRun {
        let resolver = ScriptedKeyResolver(
            sourceRows: [
                diffIdRow(1, name: "a"),
                diffIdRow(2, name: "b"),
                diffIdRow(3, name: "c-source"),
                diffIdRow(4, name: "d")
            ],
            targetRows: [
                diffIdRow(1, name: "a"),
                diffIdRow(2, name: "b-target"),
                diffIdRow(3, name: "c"),
                diffIdRow(5, name: "e")
            ]
        )
        let sourceRows = [diffIdRow(1, name: "a"), diffIdRow(2, name: "b"), diffIdRow(4, name: "d")]
        let targetRows = [diffIdRow(1, name: "a"), diffIdRow(3, name: "c"), diffIdRow(5, name: "e")]
        var sinkEntries: [RowDiffEntry] = []
        let summary = try await makeDiffEngine(defersOneSidedRows: true).compare(
            source: ArrayRowProvider(rows: sourceRows),
            target: ArrayRowProvider(rows: targetRows),
            resolver: resolver
        ) { entry in
            sinkEntries.append(entry)
        }
        return FilteredRun(summary: summary, resolver: resolver, sinkEntries: sinkEntries)
    }

    private func entry(_ key: String, in summary: DataDiffSummary) throws -> RowDiffEntry {
        let matches = summary.entries.filter { $0.keyIdentity == key }
        XCTAssertEqual(matches.count, 1, "key \(key) must be classified exactly once")
        return try XCTUnwrap(matches.first)
    }

    /// The target holds the row but its filter hid it, so writing an INSERT would hit the key.
    func testASourceOnlyKeyTheTargetHoldsOutsideItsFilterIsAConflict() async throws {
        let run = try await runFiltered()
        let conflict = try entry("2", in: run.summary)

        XCTAssertEqual(conflict.kind, .conflict)
        XCTAssertEqual(conflict.sourceRow?.value(for: "name"), .text("b"))
        XCTAssertEqual(conflict.targetRow?.value(for: "name"), .text("b-target"))
        XCTAssertTrue(conflict.differs(in: "name"))
    }

    func testASourceOnlyKeyTheTargetDoesNotHoldIsAnInsert() async throws {
        let run = try await runFiltered()
        let insert = try entry("4", in: run.summary)

        XCTAssertEqual(insert.kind, .insert)
        XCTAssertEqual(insert.sourceRow?.value(for: "name"), .text("d"))
        XCTAssertNil(insert.targetRow)
    }

    func testATargetOnlyKeyTheSourceHoldsOutsideItsFilterIsAConflict() async throws {
        let run = try await runFiltered()
        let conflict = try entry("3", in: run.summary)

        XCTAssertEqual(conflict.kind, .conflict)
        XCTAssertEqual(conflict.sourceRow?.value(for: "name"), .text("c-source"))
        XCTAssertEqual(conflict.targetRow?.value(for: "name"), .text("c"))
    }

    func testATargetOnlyKeyTheSourceDoesNotHoldIsADelete() async throws {
        let run = try await runFiltered()
        let delete = try entry("5", in: run.summary)

        XCTAssertEqual(delete.kind, .delete)
        XCTAssertNil(delete.sourceRow)
        XCTAssertEqual(delete.targetRow?.value(for: "name"), .text("e"))
    }

    func testAConflictIsCountedApartFromTheDifferences() async throws {
        let run = try await runFiltered()

        XCTAssertEqual(run.summary.conflictCount, 2)
        XCTAssertEqual(run.summary.count(of: .conflict), 2)
        XCTAssertEqual(run.summary.insertCount, 1)
        XCTAssertEqual(run.summary.deleteCount, 1)
        XCTAssertEqual(run.summary.updateCount, 0)
        XCTAssertEqual(run.summary.identicalCount, 1)
        XCTAssertEqual(run.summary.differenceCount, 2, "a conflict is not something the sync writes")
        XCTAssertEqual(run.summary.totalCount, 5)
        XCTAssertFalse(RowDiffKind.conflict.isDifference)
    }

    /// The walk keeps one-sided keys, not one-sided rows, so a filtered comparison of a table with
    /// millions of unmatched rows costs a key each rather than a row each. Both sides are then read
    /// back by key: the side that held the row no longer has it in hand.
    func testDeferredKeysAreLookedUpOnBothSides() async throws {
        let run = try await runFiltered()

        XCTAssertEqual(run.resolver.calls, [
            ScriptedKeyResolver.Call(keys: [[.text("2")], [.text("4")]], side: .source),
            ScriptedKeyResolver.Call(keys: [[.text("2")], [.text("4")]], side: .target),
            ScriptedKeyResolver.Call(keys: [[.text("3")], [.text("5")]], side: .target),
            ScriptedKeyResolver.Call(keys: [[.text("3")], [.text("5")]], side: .source)
        ])
    }

    func testTheEntrySinkSeesTheConflictEntries() async throws {
        let run = try await runFiltered()
        let conflicts = run.sinkEntries.filter { $0.kind == .conflict }

        XCTAssertEqual(run.sinkEntries.map(\.kind), [.identical, .conflict, .insert, .conflict, .delete])
        XCTAssertEqual(conflicts.map(\.keyIdentity), ["2", "3"])
        XCTAssertTrue(conflicts.allSatisfy { $0.sourceRow != nil && $0.targetRow != nil })
    }

    func testTheResolverIsAskedForAtMostTwoHundredKeysAtATime() async throws {
        let sourceRows = (1 ... 450).map { diffIdRow($0) }
        let targetRows = (1_000 ... 1_200).map { diffIdRow($0) }
        let resolver = ScriptedKeyResolver(sourceRows: sourceRows, targetRows: targetRows)
        let summary = try await runDiff(
            source: sourceRows,
            target: targetRows,
            engine: makeDiffEngine(defersOneSidedRows: true),
            resolver: resolver
        )

        XCTAssertEqual(summary.insertCount, 450)
        XCTAssertEqual(summary.deleteCount, 201)
        XCTAssertEqual(resolver.calls.map(\.keys.count), [200, 200, 200, 200, 50, 50, 200, 200, 1, 1])
        XCTAssertEqual(
            resolver.calls.map(\.side),
            [.source, .target, .source, .target, .source, .target, .target, .source, .target, .source]
        )
        XCTAssertEqual(
            resolver.calls.prefix(6).filter { $0.side == .source }.flatMap(\.keys),
            (1 ... 450).map { [PluginCellValue.text(String($0))] },
            "every deferred key is looked up exactly once, in walk order"
        )
    }

    /// A key read from a side's own stream that the same side cannot hand back is a row that moved
    /// under the comparison, or a lookup matching nothing at all. Both are silent, and silence here
    /// reads as two databases that agree.
    func testADeferredKeyItsOwnSideCannotReadBackFailsTheComparison() async {
        do {
            _ = try await runDiff(
                source: [diffIdRow(1)],
                target: [],
                engine: makeDiffEngine(defersOneSidedRows: true),
                resolver: ScriptedKeyResolver()
            )
            XCTFail("Expected a comparison that lost a deferred row to fail")
        } catch let error as CompareSyncError {
            guard case .rowsChangedSinceComparison = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAFilteredComparisonWithNoResolverThrowsRatherThanGuessing() async {
        do {
            _ = try await runDiff(
                source: [diffIdRow(1)],
                target: [],
                engine: makeDiffEngine(defersOneSidedRows: true)
            )
            XCTFail("Expected a filtered comparison without a resolver to fail")
        } catch {
            XCTAssertTrue(error is CompareSyncError, "unexpected error \(error)")
        }
    }

    func testAFilteredComparisonThatMatchesEveryKeyNeedsNoResolver() async throws {
        let summary = try await runDiff(
            source: [diffIdRow(1, name: "a"), diffIdRow(2, name: "b")],
            target: [diffIdRow(1, name: "a"), diffIdRow(2, name: "z")],
            engine: makeDiffEngine(defersOneSidedRows: true)
        )

        XCTAssertEqual(summary.identicalCount, 1)
        XCTAssertEqual(summary.updateCount, 1)
    }

    func testADuplicateKeyAmongTheResolvedRowsThrows() async {
        let resolver = ScriptedKeyResolver(
            sourceRows: [diffIdRow(2, name: "b")],
            targetRows: [diffIdRow(2, name: "first"), diffIdRow(2, name: "second")]
        )

        do {
            _ = try await runDiff(
                source: [diffIdRow(1, name: "a"), diffIdRow(2, name: "b")],
                target: [diffIdRow(1, name: "a")],
                engine: makeDiffEngine(defersOneSidedRows: true),
                resolver: resolver
            )
            XCTFail("Expected a duplicate key error")
        } catch let error as CompareSyncError {
            guard case .duplicateKey = error else {
                return XCTFail("Expected duplicateKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
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
            .text("109.05999755859381"),
            as: .numeric
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
            let forward = subject.compare(.text(left), .text(right), as: .numeric)
            let backward = subject.compare(.text(right), .text(left), as: .numeric)
            XCTAssertEqual(
                forward.isEqual,
                backward.isEqual,
                "comparison of \(left) and \(right) must not depend on argument order"
            )
        }
    }

    func testFloatToleranceOnlyAppliesToANumericColumn() {
        let subject = comparator(tolerance: 0.5)

        XCTAssertTrue(subject.compare(.text("1.0"), .text("1.2"), as: .numeric).isEqual)
        XCTAssertFalse(subject.compare(.text("1.0"), .text("1.2"), as: .other).isEqual)
        XCTAssertEqual(subject.compare(.text("1.0"), .text("1.2"), as: .other).rule, .exactValue)
        XCTAssertFalse(subject.compare(.text("1.0"), .text("1.2"), as: .temporal).isEqual)
    }

    func testANumericColumnWhoseTextIsNotANumberComparesExactly() {
        let outcome = comparator(tolerance: 1).compare(.text("n/a"), .text("N/A"), as: .numeric)

        XCTAssertFalse(outcome.isEqual)
        XCTAssertEqual(outcome.rule, .exactValue)
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
        let outcome = comparator(tolerance: 0).compare(.text("1.0"), .text("1.00"), as: .numeric)

        XCTAssertFalse(outcome.isEqual, "without a declared tolerance nothing is smoothed over")
    }

    func testEquivalentInstantsWithDifferentOffsetsCompareEqual() {
        let outcome = comparator().compare(
            .text("1999-01-15 08:00:00-08:00"),
            .text("1999-01-15 11:00:00-05:00"),
            as: .temporal
        )

        XCTAssertTrue(outcome.isEqual, "the same instant written at two offsets is not a difference")
        XCTAssertEqual(outcome.rule, .timestampPrecision)
    }

    func testOffsetsAreOnlyReconciledForATemporalColumn() {
        let subject = comparator()
        let left = PluginCellValue.text("1999-01-15 08:00:00-08:00")
        let right = PluginCellValue.text("1999-01-15 11:00:00-05:00")

        XCTAssertFalse(subject.compare(left, right, as: .other).isEqual)
        XCTAssertFalse(subject.compare(left, right, as: .numeric).isEqual)
    }

    func testTimestampPrecisionTruncationIsHonoured() {
        let coarse = comparator(fractionalDigits: 0).compare(
            .text("2026-01-01 00:00:00.100000"),
            .text("2026-01-01 00:00:00.200000"),
            as: .temporal
        )
        XCTAssertTrue(coarse.isEqual)

        let fine = comparator(fractionalDigits: 6).compare(
            .text("2026-01-01 00:00:00.100000"),
            .text("2026-01-01 00:00:00.200000"),
            as: .temporal
        )
        XCTAssertFalse(fine.isEqual)
    }

    func testATemporalColumnHoldingUnparseableTextComparesExactly() {
        let outcome = comparator().compare(.text("soon"), .text("later"), as: .temporal)

        XCTAssertFalse(outcome.isEqual)
        XCTAssertEqual(outcome.rule, .exactValue)
    }

    func testIdenticalTextIsEqualUnderEveryKind() {
        let subject = comparator()

        for kind in [ValueComparisonKind.numeric, .temporal, .other] {
            let outcome = subject.compare(.text("x"), .text("x"), as: kind)
            XCTAssertTrue(outcome.isEqual, "identical text must be equal as \(kind)")
            XCTAssertEqual(outcome.rule, .exactValue)
        }
    }

    func testNullOnlyEqualsNull() {
        let subject = comparator()

        XCTAssertTrue(subject.compare(.null, .null).isEqual)
        XCTAssertEqual(subject.compare(.null, .null).rule, .nullEquality)
        XCTAssertFalse(subject.compare(.null, .text("")).isEqual)
        XCTAssertEqual(subject.compare(.null, .text("")).rule, .nullEquality)
    }

    func testTextAgainstBytesIsATypeMismatch() {
        let outcome = comparator().compare(.text("x"), .bytes(Data([0x78])))

        XCTAssertFalse(outcome.isEqual)
        XCTAssertEqual(outcome.rule, .typeMismatch)
    }

    func testBinaryContentComparedByBytes() {
        let subject = comparator()

        XCTAssertTrue(subject.compare(.bytes(Data([1, 2, 3])), .bytes(Data([1, 2, 3]))).isEqual)
        XCTAssertFalse(subject.compare(.bytes(Data([1, 2, 3])), .bytes(Data([1, 2, 4]))).isEqual)
        XCTAssertEqual(subject.compare(.bytes(Data([1])), .bytes(Data([2]))).rule, .binaryContent)
    }

    func testColumnTypesChooseTheirComparisonKind() {
        XCTAssertEqual(ValueComparisonKind(columnType: .integer(rawType: "int")), .numeric)
        XCTAssertEqual(ValueComparisonKind(columnType: .decimal(rawType: "numeric(10,2)")), .numeric)
        XCTAssertEqual(ValueComparisonKind(columnType: .timestamp(rawType: "timestamptz")), .temporal)
        XCTAssertEqual(ValueComparisonKind(columnType: .date(rawType: "date")), .temporal)
        XCTAssertEqual(ValueComparisonKind(columnType: .datetime(rawType: "datetime")), .temporal)
        XCTAssertEqual(ValueComparisonKind(columnType: .text(rawType: "varchar(20)")), .other)
        XCTAssertEqual(ValueComparisonKind(columnType: .blob(rawType: "blob")), .other)
        XCTAssertEqual(ValueComparisonKind(columnType: nil), .unknown)
    }
}
