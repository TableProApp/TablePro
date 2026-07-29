//
//  FileConflictDiffTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FileConflictDiff")
struct FileConflictDiffTests {
    @Test("identical content produces only unchanged pairs")
    func identicalContentIsUnchanged() {
        let pairs = FileConflictDiff.pairs(mine: "a\nb", disk: "a\nb")

        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.kind == .unchanged })
    }

    @Test("a replaced line is reported as changed with both sides")
    func replacedLineIsChanged() {
        let pairs = FileConflictDiff.pairs(mine: "a\nb", disk: "a\nc")

        #expect(pairs.contains(DiffPair(before: "b", after: "c", kind: .changed)))
    }

    @Test("conflict lines keep boundary whitespace that SQL normalization would trim")
    func conflictLinesKeepBoundaryWhitespace() {
        let content = "\nSELECT 1\n"

        #expect(FileConflictDiff.lines(content) == ["", "SELECT 1", ""])
        #expect(SqlNormalizer.lines(content) == ["SELECT 1"])
    }

    @Test("a file that gained a trailing blank line reads as a real difference")
    func trailingBlankLineIsADifference() {
        let pairs = FileConflictDiff.pairs(mine: "a", disk: "a\n")

        #expect(pairs.contains { $0.kind != .unchanged })
    }

    @Test("a CRLF file splits into lines instead of collapsing into one")
    func crlfSplitsIntoLines() {
        #expect(FileConflictDiff.lines("a\r\nb") == ["a", "b"])
        #expect(FileConflictDiff.lines("a\rb") == ["a", "b"])
    }

    @Test("a CRLF file diffs line by line against its LF twin")
    func crlfDiffsLineByLine() {
        let pairs = FileConflictDiff.pairs(mine: "a\r\nb\r\nc", disk: "a\nx\nc")

        #expect(pairs.count == 3)
        #expect(pairs.contains(DiffPair(before: "b", after: "x", kind: .changed)))
    }
}
