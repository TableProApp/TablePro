//
//  FileConflictPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FileConflictPresentation")
struct FileConflictPresentationTests {
    @Test("an unchanged line is plain on both sides")
    func unchangedIsPlain() {
        #expect(FileConflictRowHighlight(kind: .unchanged, side: .mine) == .plain)
        #expect(FileConflictRowHighlight(kind: .unchanged, side: .disk) == .plain)
    }

    @Test("a removed line is marked on your side and leaves a filler on disk")
    func removedMarksMineAndFillsDisk() {
        #expect(FileConflictRowHighlight(kind: .removed, side: .mine) == .removed)
        #expect(FileConflictRowHighlight(kind: .removed, side: .disk) == .filler)
    }

    @Test("an added line is marked on disk and leaves a filler on your side")
    func addedMarksDiskAndFillsMine() {
        #expect(FileConflictRowHighlight(kind: .added, side: .disk) == .added)
        #expect(FileConflictRowHighlight(kind: .added, side: .mine) == .filler)
    }

    @Test("a changed line is removed on your side and added on disk")
    func changedMarksBothSides() {
        #expect(FileConflictRowHighlight(kind: .changed, side: .mine) == .removed)
        #expect(FileConflictRowHighlight(kind: .changed, side: .disk) == .added)
    }

    @Test("a line diff puts each pair's sides in the matching column, row for row")
    func lineDiffFillsBothColumns() {
        let presentation = FileConflictPresentation(comparison: .lineDiff([
            DiffPair(before: "a", after: "a", kind: .unchanged),
            DiffPair(before: "b", after: nil, kind: .removed),
            DiffPair(before: nil, after: "c", kind: .added),
            DiffPair(before: "d", after: "e", kind: .changed)
        ]))

        #expect(presentation.showsLineDiff)
        #expect(presentation.mineRows == [
            FileConflictRow(id: 0, text: "a", highlight: .plain),
            FileConflictRow(id: 1, text: "b", highlight: .removed),
            FileConflictRow(id: 2, text: nil, highlight: .filler),
            FileConflictRow(id: 3, text: "d", highlight: .removed)
        ])
        #expect(presentation.diskRows == [
            FileConflictRow(id: 0, text: "a", highlight: .plain),
            FileConflictRow(id: 1, text: nil, highlight: .filler),
            FileConflictRow(id: 2, text: "c", highlight: .added),
            FileConflictRow(id: 3, text: "e", highlight: .added)
        ])
    }

    @Test("without a line diff each column lists its own file, untinted")
    func withoutLineDiffListsEachFile() {
        let presentation = FileConflictPresentation(
            comparison: .withoutLineDiff(mine: ["a", "b", "c"], disk: ["x"])
        )

        #expect(!presentation.showsLineDiff)
        #expect(presentation.mineRows == [
            FileConflictRow(id: 0, text: "a", highlight: .plain),
            FileConflictRow(id: 1, text: "b", highlight: .plain),
            FileConflictRow(id: 2, text: "c", highlight: .plain)
        ])
        #expect(presentation.diskRows == [FileConflictRow(id: 0, text: "x", highlight: .plain)])
    }

    @Test("loading builds the presentation of the two files' comparison")
    func loadMatchesTheComparison() async {
        let mine = "SELECT 1;\nSELECT 2;\n"
        let disk = "SELECT 1;\nSELECT 3;\n"

        let loaded = await FileConflictPresentation.load(mine: mine, disk: disk)

        #expect(loaded == FileConflictPresentation(comparison: FileConflictDiff.comparison(mine: mine, disk: disk)))
        #expect(loaded.showsLineDiff)
    }

    @Test("loading a rewrite over the limit shows both files without a line diff")
    func loadOverTheLimitSkipsTheLineDiff() async {
        let lineCount = FileConflictDiff.maximumDifferingLineCount + 1
        let mine = (1...lineCount).map { "SELECT \($0);" }.joined(separator: "\n")
        let disk = (1...lineCount).map { "UPDATE t SET c = \($0);" }.joined(separator: "\n")

        let loaded = await FileConflictPresentation.load(mine: mine, disk: disk)

        #expect(!loaded.showsLineDiff)
        #expect(loaded.mineRows.count == lineCount)
        #expect(loaded.diskRows.count == lineCount)
        #expect(loaded.mineRows.allSatisfy { $0.highlight == .plain })
    }
}
