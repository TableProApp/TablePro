//
//  FileConflictDiff.swift
//  TablePro
//

import Foundation

internal enum FileConflictComparison: Equatable, Sendable {
    case lineDiff([DiffPair])
    case withoutLineDiff(mine: [String], disk: [String])
}

/// Line splitting for the file-conflict sheet. This deliberately does not reuse
/// `SqlNormalizer`, which trims boundary whitespace and rewrites line endings:
/// a conflict sheet compares file bytes, so leading or trailing blank lines are a
/// real difference the user needs to see.
internal enum FileConflictDiff {
    static let maximumDifferingLineCount = 2_000

    // "\r\n" is one Character, so line endings are folded by code unit before splitting.
    static func lines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
            .replacingOccurrences(of: "\r", with: "\n", options: .literal)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func comparison(mine: String, disk: String) -> FileConflictComparison {
        let mineLines = lines(mine)
        let diskLines = lines(disk)
        let span = DifferingSpan(mine: mineLines, disk: diskLines)
        guard span.mineRange.count <= maximumDifferingLineCount,
              span.diskRange.count <= maximumDifferingLineCount
        else {
            return .withoutLineDiff(mine: mineLines, disk: diskLines)
        }
        return .lineDiff(alignedPairs(mine: mineLines, disk: diskLines, span: span))
    }

    private static func alignedPairs(mine: [String], disk: [String], span: DifferingSpan) -> [DiffPair] {
        let leading = mine[..<span.mineRange.lowerBound].map(unchangedPair)
        let differing = DiffComputer.computeSplit(
            before: Array(mine[span.mineRange]),
            after: Array(disk[span.diskRange])
        )
        let trailing = mine[span.mineRange.upperBound...].map(unchangedPair)
        return leading + differing + trailing
    }

    private static func unchangedPair(_ line: String) -> DiffPair {
        DiffPair(before: line, after: line, kind: .unchanged)
    }

    private struct DifferingSpan {
        let mineRange: Range<Int>
        let diskRange: Range<Int>

        init(mine: [String], disk: [String]) {
            let shorterCount = min(mine.count, disk.count)
            var sharedPrefixCount = 0
            while sharedPrefixCount < shorterCount, mine[sharedPrefixCount] == disk[sharedPrefixCount] {
                sharedPrefixCount += 1
            }
            var sharedSuffixCount = 0
            while sharedSuffixCount < shorterCount - sharedPrefixCount,
                  mine[mine.count - 1 - sharedSuffixCount] == disk[disk.count - 1 - sharedSuffixCount] {
                sharedSuffixCount += 1
            }
            mineRange = sharedPrefixCount..<(mine.count - sharedSuffixCount)
            diskRange = sharedPrefixCount..<(disk.count - sharedSuffixCount)
        }
    }
}
