//
//  FoldPreviewMetricsTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing
@testable import TablePro

@Suite("Fold preview metrics")
struct FoldPreviewMetricsTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @Test("A block keeps every line when it fits")
    func shortBlockIsShownWhole() {
        let block = "CREATE TABLE users (\n    id BIGSERIAL,\n    name TEXT\n);"
        let layout = FoldPreviewMetrics.layout(for: block, font: font)

        #expect(layout.text == block)
        #expect(layout.hiddenLineCount == 0)
    }

    @Test("A block longer than the cap is trimmed and the rest is counted")
    func longBlockReportsWhatItLeftOut() {
        let lines = (0..<40).map { "    column_\($0) TEXT," }
        let block = (["CREATE TABLE wide ("] + lines + [");"]).joined(separator: "\n")
        let layout = FoldPreviewMetrics.layout(for: block, font: font)

        #expect(layout.text.components(separatedBy: "\n").count == FoldPreviewMetrics.maxLines)
        #expect(layout.hiddenLineCount == 42 - FoldPreviewMetrics.maxLines)
        #expect(layout.text.hasPrefix("CREATE TABLE wide ("))
    }

    @Test("The trailing newline a line range carries never becomes an empty row")
    func trailingBlankLinesAreDropped() {
        let layout = FoldPreviewMetrics.layout(for: "BEGIN\n    SELECT 1;\nEND;\n", font: font)

        #expect(layout.text == "BEGIN\n    SELECT 1;\nEND;")
        #expect(layout.hiddenLineCount == 0)
    }

    @Test("Every peek is large enough to appear")
    func sizeIsAlwaysUsable() {
        for block in ["x", "", "CREATE TABLE t (\n  a INT\n);"] {
            let layout = FoldPreviewMetrics.layout(for: block, font: font)
            #expect(layout.size.width >= FoldPreviewMetrics.minWidth, "got \(layout.size) for \(block)")
            #expect(layout.size.height > 0, "got \(layout.size) for \(block)")
        }
    }

    @Test("A wide block stops growing at the cap")
    func widthIsCapped() {
        let block = String(repeating: "SELECT ", count: 400)
        let layout = FoldPreviewMetrics.layout(for: block, font: font)

        #expect(layout.size.width == FoldPreviewMetrics.maxWidth)
    }

    @Test("A taller block is a taller peek")
    func heightTracksLineCount() {
        let short = FoldPreviewMetrics.layout(for: "a\nb", font: font)
        let tall = FoldPreviewMetrics.layout(for: "a\nb\nc\nd\ne", font: font)

        #expect(tall.size.height > short.size.height)
    }
}
