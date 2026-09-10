//
//  ColumnReorderPolicyTests.swift
//  TablePro
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column Reorder Policy")
struct ColumnReorderPolicyTests {
    private func resolve(
        support: ColumnReorderSupport = .alter,
        isColumnsTab: Bool = true,
        isTable: Bool = true,
        canEditSchema: Bool = true,
        hasStagedChanges: Bool = false,
        isRearranged: Bool = false
    ) -> ColumnReorderAvailability {
        ColumnReorderPolicy.resolve(
            support: support,
            engineName: "PostgreSQL",
            isColumnsTab: isColumnsTab,
            isTable: isTable,
            canEditSchema: canEditSchema,
            hasStagedChanges: hasStagedChanges,
            isRearranged: isRearranged
        )
    }

    @Test("A positional engine on a clean column list can reorder")
    func alterEngineIsAvailable() {
        #expect(resolve() == .available(.alter))
    }

    @Test("A rebuild engine is available too, and says so, because the cost is decided later")
    func rebuildEngineIsAvailable() {
        #expect(resolve(support: .rebuild) == .available(.rebuild))
    }

    @Test("An engine that cannot reorder names itself in the reason")
    func unsupportedEngineExplainsItself() {
        let availability = resolve(support: .unsupported)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    @Test("A list that has no order to change is not explained, only withheld")
    func nonColumnTabIsNotApplicable() {
        #expect(resolve(isColumnsTab: false) == .notApplicable)
        #expect(resolve(isColumnsTab: false).unavailableReason == nil)
    }

    @Test("An engine whose structure is read-only is withheld before its reorder support is read")
    func readOnlyStructureOutranksSupport() {
        let availability = resolve(support: .alter, canEditSchema: false)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    @Test("Staged edits withhold the drag, because a reorder runs against the saved table")
    func stagedChangesWithholdTheDrag() {
        let availability = resolve(hasStagedChanges: true)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("Staged edits on an engine that cannot reorder report the engine, not the edits")
    func unsupportedOutranksStagedChanges() {
        let availability = resolve(support: .unsupported, hasStagedChanges: true)
        #expect(availability.unavailableReason?.contains("PostgreSQL") == true)
    }

    /// A drop reports a position in what is on screen. Filtered or sorted, that is not the table's
    /// order, and the delegate hands the position over without mapping it back, so the drag is
    /// withheld rather than acted on against the wrong column.
    /// Every mechanism emits table DDL, and the SQLite one looks its target up as a table, so a
    /// view drag would end in a statement error instead of an explanation.
    @Test("A view is withheld, whatever the engine can do to a table")
    func viewWithholdsTheDrag() {
        let availability = resolve(isTable: false)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("A filtered or sorted column list withholds the drag")
    func rearrangedListWithholdsTheDrag() {
        let availability = resolve(isRearranged: true)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason != nil)
    }

    @Test("Staged edits outrank a rearranged list, because saving is the first thing to do")
    func stagedChangesOutrankRearrangement() {
        let staged = resolve(hasStagedChanges: true, isRearranged: true)
        #expect(staged.unavailableReason == resolve(hasStagedChanges: true).unavailableReason)
    }
}

/// The commands go through the same `desiredOrder` a drop does, so they are checked against it
/// rather than against the index they happen to produce.
@Suite("Column Move")
@MainActor
struct ColumnMoveTests {
    private let columns = ["a", "b", "c", "d"]

    private func order(movingRow row: Int, _ direction: ColumnMove.Direction) throws -> [String] {
        try StructureColumnReorderHandler.desiredOrder(
            fromIndex: row,
            toIndex: ColumnMove.dropIndex(movingRow: row, direction),
            columnNames: columns
        )
    }

    @Test("Up swaps a column with the one before it")
    func upSwapsWithThePrecedingColumn() throws {
        #expect(try order(movingRow: 2, .up) == ["a", "c", "b", "d"])
        #expect(try order(movingRow: 1, .up) == ["b", "a", "c", "d"])
    }

    @Test("Down swaps a column with the one after it, drop index counting its old place")
    func downSwapsWithTheFollowingColumn() throws {
        #expect(try order(movingRow: 1, .down) == ["a", "c", "b", "d"])
        #expect(try order(movingRow: 2, .down) == ["a", "b", "d", "c"])
    }

    @Test("The ends offer only the direction that has somewhere to go")
    func theEndsOfferOneDirection() {
        #expect(!ColumnMove.isPossible(movingRow: 0, .up, columnCount: 4))
        #expect(ColumnMove.isPossible(movingRow: 0, .down, columnCount: 4))
        #expect(ColumnMove.isPossible(movingRow: 3, .up, columnCount: 4))
        #expect(!ColumnMove.isPossible(movingRow: 3, .down, columnCount: 4))
    }

    /// A reused row view carries the last row's index, and a menu built before the count arrives
    /// would otherwise offer a move off the end of the list.
    @Test("A row index outside the column count offers neither direction")
    func anOutOfRangeRowOffersNothing() {
        #expect(!ColumnMove.isPossible(movingRow: 0, .up, columnCount: 0))
        #expect(!ColumnMove.isPossible(movingRow: 0, .down, columnCount: 0))
        #expect(!ColumnMove.isPossible(movingRow: 7, .up, columnCount: 4))
        #expect(!ColumnMove.isPossible(movingRow: 7, .down, columnCount: 4))
    }
}
