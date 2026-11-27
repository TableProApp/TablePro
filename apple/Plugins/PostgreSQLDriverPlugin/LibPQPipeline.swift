//
//  LibPQPipeline.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

nonisolated struct LibPQPipelineStatement: Sendable {
    let query: String
    let parameters: [PluginCellValue]
}

// libpq hands a pipeline's results back in send order, each statement's ending with a null, and an error aborts every
// statement after it up to the Sync.
nonisolated struct LibPQPipelineTally {
    enum Answer {
        case completed(rowsAffected: Int, commandTag: String?)
        case failed(any Error)
        case aborted
    }

    private(set) var answers: [Answer] = []
    private(set) var times: [TimeInterval] = []
    private var pending: Answer?
    private var rowsSoFar = 0
    private var lastArrival: Date
    private let total: Int
    var sent = 0
    private(set) var receivedSync = false

    init(total: Int, startedAt: Date) {
        self.total = total
        lastArrival = startedAt
    }

    // Asking libpq for a result past the last one sent would read a null that ends no statement.
    var awaitsStatement: Bool {
        answers.count < sent
    }

    var isComplete: Bool {
        receivedSync
    }

    mutating func take(_ answer: Answer) {
        guard pending == nil else { return }
        if case .completed(let rowsAffected, let commandTag) = answer {
            pending = .completed(rowsAffected: rowsAffected + rowsSoFar, commandTag: commandTag)
        } else {
            pending = answer
        }
    }

    // Rows read in a chunk, counted and dropped, as a lone read past its limit counts and drops them.
    mutating func takeRows(_ count: Int) {
        rowsSoFar += count
    }

    mutating func takeSync() {
        receivedSync = true
    }

    // False for a null with no statement behind it, which only a broken connection produces.
    mutating func endStatement(at arrival: Date = Date()) -> Bool {
        guard awaitsStatement, let answer = pending else { return false }
        answers.append(answer)
        times.append(arrival.timeIntervalSince(lastArrival))
        lastArrival = arrival
        pending = nil
        rowsSoFar = 0
        return true
    }

    // Stops at the first failure; an aborted statement never ran, so it has no outcome. `cutShort` is why the exchange
    // ended early: the failure of the first statement with no answer, or of the last one when its Sync never came.
    func outcomes(cutShort: (any Error)?) -> [PluginBatchStatementOutcome] {
        var outcomes: [PluginBatchStatementOutcome] = []
        answers: for (answer, time) in zip(answers, times) {
            switch answer {
            case .completed(let rowsAffected, _):
                outcomes.append(.succeeded(rowsAffected: rowsAffected, executionTime: time))
            case .failed(let error):
                outcomes.append(.failed(error))
                return outcomes
            case .aborted:
                break answers
            }
        }
        guard let cutShort else { return outcomes }
        if outcomes.count < total {
            outcomes.append(.failed(cutShort))
        } else if !outcomes.isEmpty {
            outcomes[outcomes.count - 1] = .failed(cutShort)
        }
        return outcomes
    }

    var commandTags: [String] {
        answers.compactMap {
            guard case .completed(_, let tag) = $0 else { return nil }
            return tag
        }
    }
}

nonisolated struct LibPQPipelineAdmission {
    // A pipeline runs on the extended protocol, where these either fail or end the block the batch relies on.
    private static let refusedKeywords: Set<String> = [
        "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE", "PREPARE", "COPY",
        "VACUUM", "CHECKPOINT", "CALL", "DO", "LISTEN", "UNLISTEN", "NOTIFY", "DISCARD", "RESET", "SET",
    ]

    private let grammar: SQLLexicalGrammar

    // The session decides only whether a backslash escapes in a plain literal (`standard_conforming_strings`).
    init(session: PluginSessionLexicalState?) {
        let facts = session.map {
            SQLSessionLexicalFacts(
                determined: .backslashEscapesInSingleQuotes,
                enabled: $0.enabled.contains(.backslashEscapesInSingleQuotes) ? .backslashEscapesInSingleQuotes : []
            )
        }
        grammar = SQLLexicalReadings.resolve(
            databaseTypeId: PostgreSQLPlugin.databaseTypeId, declared: nil, session: facts
        ).execution
    }

    // The extended protocol also refuses a text holding a second statement, which a lone simple Query runs whole.
    func admits(_ query: String) -> Bool {
        guard let keyword = SQLStatementRowLimit.leadingKeyword(query, grammar: grammar),
              !Self.refusedKeywords.contains(keyword)
        else { return false }
        return SQLStatementScanner.executableStatements(in: query, grammar: grammar).count == 1
    }
}
