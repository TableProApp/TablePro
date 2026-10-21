//
//  ColumnTypeCorpusReport.swift
//  ColumnTypeCorpus
//

import Foundation

struct ColumnTypeCorpusReport: Sendable {
    enum Outcome: Sendable, Equatable {
        case passed
        case failed(String)
        case knownIssue(String)
        case skipped(String)
    }

    struct Entry: Sendable {
        let column: String
        let step: String
        let outcome: Outcome

        var line: String {
            switch outcome {
            case .passed: "ok     \(column)  \(step)"
            case .failed(let detail): "FAIL   \(column)  \(step): \(detail)"
            case .knownIssue(let detail): "known  \(column)  \(step): \(detail)"
            case .skipped(let reason): "skip   \(column)  \(step): \(reason)"
            }
        }
    }

    private(set) var entries: [Entry] = []
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    var failures: [String] {
        entries.compactMap { entry in
            guard case .failed = entry.outcome else { return nil }
            return entry.line
        }
    }

    mutating func record(_ column: String, _ step: String, _ outcome: Outcome) {
        let entry = Entry(column: column, step: step, outcome: outcome)
        entries.append(entry)
        log(entry.line)
    }

    // A step the corpus marks known passes only while it still fails, so a fix forces the marker out.
    mutating func record(
        _ column: ColumnTypeCorpus.Column,
        _ step: ColumnTypeCorpus.Step,
        problems: [String]
    ) {
        let known = column.known[step]
        switch (problems.isEmpty, known) {
        case (true, nil):
            record(column.type, step.rawValue, .passed)
        case (true, let issue?):
            record(column.type, step.rawValue, .failed("passes now, remove the known issue \"\(issue.defect)\""))
        case (false, nil):
            record(column.type, step.rawValue, .failed(problems.joined(separator: "; ")))
        case (false, let issue?):
            let others = problems.filter { $0.range(of: issue.matches, options: .regularExpression) == nil }
            if others.isEmpty {
                record(column.type, step.rawValue, .knownIssue("\(issue.defect) (\(problems.joined(separator: "; ")))"))
            } else {
                record(
                    column.type,
                    step.rawValue,
                    .failed("not the known issue \"\(issue.defect)\": \(others.joined(separator: "; "))")
                )
            }
        }
    }
}
