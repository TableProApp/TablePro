//
//  FileConflictDiffTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FileConflictDiff")
struct FileConflictDiffTests {
    private func linePairs(mine: String, disk: String) -> [DiffPair]? {
        guard case .lineDiff(let pairs) = FileConflictDiff.comparison(mine: mine, disk: disk) else {
            return nil
        }
        return pairs
    }

    private func numberedLines(_ count: Int, prefix: String) -> [String] {
        (1...count).map { "\(prefix) \($0)" }
    }

    @Test("identical content produces only unchanged pairs")
    func identicalContentIsUnchanged() throws {
        let pairs = try #require(linePairs(mine: "a\nb", disk: "a\nb"))

        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.kind == .unchanged })
    }

    @Test("a replaced line is reported as changed with both sides")
    func replacedLineIsChanged() throws {
        let pairs = try #require(linePairs(mine: "a\nb", disk: "a\nc"))

        #expect(pairs.contains(DiffPair(before: "b", after: "c", kind: .changed)))
    }

    @Test("conflict lines keep boundary whitespace that SQL normalization would trim")
    func conflictLinesKeepBoundaryWhitespace() {
        let content = "\nSELECT 1\n"

        #expect(FileConflictDiff.lines(content) == ["", "SELECT 1", ""])
        #expect(SqlNormalizer.lines(content) == ["SELECT 1"])
    }

    @Test("a file that gained a trailing blank line reads as a real difference")
    func trailingBlankLineIsADifference() throws {
        let pairs = try #require(linePairs(mine: "a", disk: "a\n"))

        #expect(pairs.contains { $0.kind != .unchanged })
    }

    @Test("a CRLF file splits into lines instead of collapsing into one")
    func crlfSplitsIntoLines() {
        #expect(FileConflictDiff.lines("a\r\nb") == ["a", "b"])
        #expect(FileConflictDiff.lines("a\rb") == ["a", "b"])
    }

    @Test("a CRLF file diffs line by line against its LF twin")
    func crlfDiffsLineByLine() throws {
        let pairs = try #require(linePairs(mine: "a\r\nb\r\nc", disk: "a\nx\nc"))

        #expect(pairs.count == 3)
        #expect(pairs.contains(DiffPair(before: "b", after: "x", kind: .changed)))
    }

    @Test("shared lines around an edit stay unchanged and keep their order")
    func sharedLinesAroundAnEditKeepTheirOrder() throws {
        let pairs = try #require(linePairs(mine: "a\nb\nc\nd", disk: "a\nx\ny\nd"))

        #expect(pairs == [
            DiffPair(before: "a", after: "a", kind: .unchanged),
            DiffPair(before: "b", after: "x", kind: .changed),
            DiffPair(before: "c", after: "y", kind: .changed),
            DiffPair(before: "d", after: "d", kind: .unchanged)
        ])
    }

    @Test("a line removed between shared lines is paired with nothing on disk")
    func removedLineBetweenSharedLines() throws {
        let pairs = try #require(linePairs(mine: "a\nb\nz", disk: "a\nz"))

        #expect(pairs == [
            DiffPair(before: "a", after: "a", kind: .unchanged),
            DiffPair(before: "b", after: nil, kind: .removed),
            DiffPair(before: "z", after: "z", kind: .unchanged)
        ])
    }

    @Test("a rewrite larger than the limit keeps both files whole without a line diff")
    func rewriteOverTheLimitSkipsTheLineDiff() {
        let lineCount = FileConflictDiff.maximumDifferingLineCount + 1
        let mineLines = numberedLines(lineCount, prefix: "SELECT")
        let diskLines = numberedLines(lineCount, prefix: "UPDATE")

        let comparison = FileConflictDiff.comparison(
            mine: mineLines.joined(separator: "\n"),
            disk: diskLines.joined(separator: "\n")
        )

        #expect(comparison == .withoutLineDiff(mine: mineLines, disk: diskLines))
    }

    @Test("a file far longer than the limit with one edited line still gets a line diff")
    func longFileWithOneEditKeepsTheLineDiff() throws {
        let lineCount = FileConflictDiff.maximumDifferingLineCount * 5
        let mineLines = numberedLines(lineCount, prefix: "SELECT")
        var diskLines = mineLines
        diskLines[lineCount / 2] = "SELECT edited"

        let pairs = try #require(linePairs(
            mine: mineLines.joined(separator: "\n"),
            disk: diskLines.joined(separator: "\n")
        ))

        let edits = pairs.filter { $0.kind != .unchanged }
        #expect(pairs.count == lineCount)
        #expect(edits == [DiffPair(before: mineLines[lineCount / 2], after: "SELECT edited", kind: .changed)])
        #expect(pairs[lineCount / 2].kind == .changed)
    }

    @Test("the limit counts the lines from the first difference to the last")
    func limitCountsTheDifferingSpan() {
        let limit = FileConflictDiff.maximumDifferingLineCount
        let atLimit = spanWithEditedEnds(lineCount: limit)
        let overLimit = spanWithEditedEnds(lineCount: limit + 1)

        #expect(isLineDiff(FileConflictDiff.comparison(mine: atLimit.mine, disk: atLimit.disk)))
        #expect(!isLineDiff(FileConflictDiff.comparison(mine: overLimit.mine, disk: overLimit.disk)))
    }

    private func spanWithEditedEnds(lineCount: Int) -> (mine: String, disk: String) {
        let shared = ["-- header"] + numberedLines(lineCount, prefix: "SELECT") + ["-- footer"]
        var edited = shared
        edited[1] = "SELECT first edited"
        edited[lineCount] = "SELECT last edited"
        return (shared.joined(separator: "\n"), edited.joined(separator: "\n"))
    }

    private func isLineDiff(_ comparison: FileConflictComparison) -> Bool {
        guard case .lineDiff = comparison else { return false }
        return true
    }
}
