//
//  VersionComparison.swift
//  TablePro
//

import Foundation

internal enum VersionComparison: Equatable, Sendable {
    case identical
    case differs([DiffPair])
    case tooLarge

    static let maximumLineCount = 5_000

    static func compare(baseline: String, current: String) -> VersionComparison {
        guard baseline != current else { return .identical }
        let before = FileConflictDiff.lines(baseline)
        let after = FileConflictDiff.lines(current)
        guard before != after else { return .identical }
        guard before.count <= maximumLineCount, after.count <= maximumLineCount else { return .tooLarge }
        return .differs(DiffComputer.computeSplit(before: before, after: after))
    }
}
