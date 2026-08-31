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

    // MARK: - Exhaustive

    /// Both planners are asked for every permutation of five columns. A tie in the common
    /// subsequence can pick a different set to leave alone without changing how many columns move,
    /// so the guarantee worth pinning is the result, not the choice.
    @Test("Every permutation of five columns is reached, by both mechanisms, in the minimum moves")
    func everyPermutationIsReachable() {
        let start = ["a", "b", "c", "d", "e"]
        for desired in permutations(of: start) {
            let moves = PluginColumnReorderPlanner.moves(from: start, to: desired)
            var byMove = start
            for move in moves {
                byMove.removeAll { $0 == move.column }
                if let after = move.afterColumn, let index = byMove.firstIndex(of: after) {
                    byMove.insert(move.column, at: byMove.index(after: index))
                } else {
                    byMove.insert(move.column, at: 0)
                }
            }
            #expect(byMove == desired, "moves did not reach \(desired)")
            #expect(moves.count == start.count - longestCommonSubsequenceLength(start, desired))

            var byCycle = start
            for column in PluginColumnReorderPlanner.appendCycle(from: start, to: desired) {
                byCycle.removeAll { $0 == column }
                byCycle.append(column)
            }
            #expect(byCycle == desired, "cycling did not reach \(desired)")
        }
    }

    private func permutations(of values: [String]) -> [[String]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[String]] in
            var rest = values
            let picked = rest.remove(at: index)
            return permutations(of: rest).map { [picked] + $0 }
        }
    }

    private func longestCommonSubsequenceLength(_ lhs: [String], _ rhs: [String]) -> Int {
        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                lengths[i][j] = lhs[i] == rhs[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        return lengths[0][0]
    }
}
