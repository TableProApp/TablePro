//
//  FileConflictDiff.swift
//  TablePro
//

import Foundation

/// Line splitting for the file-conflict sheet. This deliberately does not reuse
/// `SqlNormalizer`, which trims boundary whitespace and rewrites line endings:
/// a conflict sheet compares file bytes, so leading or trailing blank lines are a
/// real difference the user needs to see.
enum FileConflictDiff {
    /// Swift treats "\r\n" as one Character, so splitting on "\n" alone leaves a
    /// CRLF file as a single line. Line endings are folded before splitting, then
    /// blank lines are kept.
    static func lines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func pairs(mine: String, disk: String) -> [DiffPair] {
        DiffComputer.computeSplit(before: lines(mine), after: lines(disk))
    }
}
