//
//  RunResultPlan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Which statements of a run become results of their own. Two or more statements that return no
// rows share one summary, placed where the last of them ran, so the result of the last statement
// stays the last result. Only the last `maxRowResults` results that return rows are kept.
struct RunResultPlan: Equatable, Sendable {
    static let maxRowResults = 100

    enum Entry: Equatable, Sendable {
        case statement(Int)
        case summary([Int])
    }

    let entries: [Entry]
    let rowResultCount: Int
    let keptRowResultCount: Int
    private let ownPositions: [Int: Int]
    private let summarized: Set<Int>

    var droppedRowResultCount: Int { rowResultCount - keptRowResultCount }

    init(producesRows: [Bool], maxRowResults: Int = Self.maxRowResults) {
        let rowIndices = producesRows.indices.filter { producesRows[$0] }
        let kept = Set(rowIndices.suffix(max(0, maxRowResults)))
        let summarized = producesRows.indices.filter { !producesRows[$0] }
        let collapses = summarized.count >= 2

        var entries: [Entry] = []
        for index in producesRows.indices {
            if producesRows[index] {
                if kept.contains(index) { entries.append(.statement(index)) }
            } else if !collapses {
                entries.append(.statement(index))
            } else if index == summarized.last {
                entries.append(.summary(summarized))
            }
        }
        self.entries = entries
        var ownPositions: [Int: Int] = [:]
        var covered: Set<Int> = []
        for (position, entry) in entries.enumerated() {
            switch entry {
            case .statement(let index): ownPositions[index] = position
            case .summary(let indices): covered.formUnion(indices)
            }
        }
        self.ownPositions = ownPositions
        self.summarized = covered
        rowResultCount = rowIndices.count
        keptRowResultCount = kept.count
    }

    // True when the statement's rows are shown on a result of its own, so they are worth building.
    func showsRows(ofStatement index: Int) -> Bool {
        ownPositions[index] != nil
    }

    // Where the statement's own result sits among the run's results.
    func position(ofStatement index: Int) -> Int? {
        ownPositions[index]
    }

    func summarizes(statement index: Int) -> Bool {
        summarized.contains(index)
    }

    var droppedNotice: String? {
        guard droppedRowResultCount > 0 else { return nil }
        return String(
            format: String(localized: "Showing the last %1$@ of %2$@ results that returned rows."),
            keptRowResultCount.formatted(),
            rowResultCount.formatted()
        )
    }
}

struct RunSummaryPart {
    let rowsAffected: Int
    let executionTime: TimeInterval
    let serverOutput: PluginServerOutput
    let statusMessage: String?

    func withServerOutput(_ output: PluginServerOutput) -> RunSummaryPart {
        RunSummaryPart(rowsAffected: rowsAffected, executionTime: executionTime, serverOutput: output, statusMessage: statusMessage)
    }
}

extension RunSummaryPart {
    init(_ result: QueryResult) {
        self.init(
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            serverOutput: result.serverOutput,
            statusMessage: result.statusMessage
        )
    }
}
