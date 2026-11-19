//
//  LibPQPipeline.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

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
        if pending == nil { pending = answer }
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

nonisolated enum LibPQPipelineAdmission {
    // A pipeline runs on the extended protocol, where these either fail or end the block the batch relies on.
    private static let refusedKeywords: Set<String> = [
        "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE", "PREPARE", "COPY",
        "VACUUM", "CHECKPOINT", "CALL", "DO", "LISTEN", "UNLISTEN", "NOTIFY", "DISCARD", "RESET", "SET",
    ]

    // The extended protocol also refuses a text holding a second statement, which a lone simple Query runs whole, so
    // any `;` before the end keeps the text out, one inside a literal included.
    static func admits(_ query: String) -> Bool {
        guard let keyword = leadingKeyword(of: query), !refusedKeywords.contains(keyword) else { return false }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(text.hasSuffix(";") ? text.dropLast() : text[...]).contains(";")
    }

    // Skips whitespace, `--` line comments and nested block comments, as the server's lexer does.
    static func leadingKeyword(of query: String) -> String? {
        let scalars = Array(query.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                index += 1
            } else if scalar == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                // The server ends a line comment at a carriage return too.
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                var depth = 0
                repeat {
                    if index + 1 < scalars.count, scalars[index] == "/", scalars[index + 1] == "*" {
                        depth += 1
                        index += 2
                    } else if index + 1 < scalars.count, scalars[index] == "*", scalars[index + 1] == "/" {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                } while depth > 0 && index < scalars.count
                if depth > 0 { return nil }
            } else {
                break
            }
        }
        var word = ""
        while index < scalars.count, CharacterSet.letters.contains(scalars[index]) {
            word.unicodeScalars.append(scalars[index])
            index += 1
        }
        return word.isEmpty ? nil : word.uppercased()
    }
}
