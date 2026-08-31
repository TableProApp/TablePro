//
//  ColumnReorderPlannerTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("Column Reorder Planner")
struct ColumnReorderPlannerTests {
    private let current = ["a", "b", "c", "d"]

    // MARK: - Positional moves

    @Test("A drag that changes nothing produces no statement")
    func identityOrderProducesNoMoves() {
        #expect(PluginColumnReorderPlanner.moves(from: current, to: current).isEmpty)
    }

    /// One drag is one statement, whichever way it went. Walking the wanted order and fixing every
    /// position that disagrees passes the upward case and emits two statements for the downward
    /// one, because dragging a column down makes every column it passed disagree.
    @Test("One drag is one move, up or down", arguments: [
        ["a", "c", "b", "d"],
        ["a", "c", "d", "b"],
        ["b", "a", "c", "d"],
        ["a", "b", "d", "c"]
    ])
    func oneDragIsOneMove(desired: [String]) {
        #expect(PluginColumnReorderPlanner.moves(from: current, to: desired).count == 1)
        #expect(applyingMoves(to: desired) == desired)
    }

    @Test("A column dragged to the top is anchored on nothing, which is FIRST")
    func moveToFrontHasNoAnchor() {
        let moves = PluginColumnReorderPlanner.moves(from: current, to: ["d", "a", "b", "c"])
        #expect(moves == [PluginColumnReorderPlanner.Move(column: "d", afterColumn: nil)])
    }

    @Test("Applying the moves in order reproduces the wanted order", arguments: [
        ["d", "b", "a", "c"],
        ["d", "c", "b", "a"],
        ["b", "d", "a", "c"],
        ["c", "a", "d", "b"]
    ])
    func movesReproduceDesiredOrder(desired: [String]) {
        #expect(applyingMoves(to: desired) == desired)
    }

    private func applyingMoves(to desired: [String]) -> [String] {
        var working = current
        for move in PluginColumnReorderPlanner.moves(from: current, to: desired) {
            working.removeAll { $0 == move.column }
            if let after = move.afterColumn, let index = working.firstIndex(of: after) {
                working.insert(move.column, at: working.index(after: index))
            } else {
                working.insert(move.column, at: 0)
            }
        }
        return working
    }

    @Test("An order that is not a permutation of the current one has no answer")
    func nonPermutationProducesNoMoves() {
        #expect(PluginColumnReorderPlanner.moves(from: current, to: ["a", "b", "c"]).isEmpty)
        #expect(PluginColumnReorderPlanner.moves(from: current, to: ["a", "b", "c", "e"]).isEmpty)
    }

    // MARK: - Append cycle

    @Test("An append-only engine leaves the longest matching prefix alone")
    func appendCycleKeepsLongestPrefix() {
        #expect(PluginColumnReorderPlanner.appendCycle(from: current, to: ["a", "c", "d", "b"]) == ["b"])
        #expect(PluginColumnReorderPlanner.appendCycle(from: current, to: ["a", "c", "b", "d"]) == ["b", "d"])
    }

    @Test("An unchanged order cycles nothing")
    func appendCycleOfIdentityIsEmpty() {
        #expect(PluginColumnReorderPlanner.appendCycle(from: current, to: current).isEmpty)
    }

    @Test("Appending the cycled columns in order reproduces the wanted order")
    func appendCycleReproducesDesiredOrder() {
        for desired in [["d", "c", "b", "a"], ["b", "a", "d", "c"], ["a", "c", "d", "b"]] {
            var working = current
            for column in PluginColumnReorderPlanner.appendCycle(from: current, to: desired) {
                working.removeAll { $0 == column }
                working.append(column)
            }
            #expect(working == desired, "cycling failed to reach \(desired)")
        }
    }

    @Test("An order that is not a permutation of the current one has no cycle")
    func nonPermutationProducesNoCycle() {
        #expect(PluginColumnReorderPlanner.appendCycle(from: current, to: ["a", "b"]).isEmpty)
    }
}
