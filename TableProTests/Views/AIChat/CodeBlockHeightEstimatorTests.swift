//
//  CodeBlockHeightEstimatorTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Code block height estimation")
struct CodeBlockHeightEstimatorTests {
    private static var font: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }

    private func height(_ code: String, width: CGFloat = 480) -> CGFloat {
        CodeBlockHeightEstimator.height(for: code, font: Self.font, availableWidth: width)
    }

    @Test("A measured height stays within the clamp")
    func heightStaysWithinClamp() {
        let tall = String(repeating: "SELECT 1;\n", count: 200)

        #expect(height("SELECT 1;") >= CodeBlockHeightEstimator.minimumHeight)
        #expect(height(tall) == CodeBlockHeightEstimator.maximumHeight)
    }

    @Test("More lines never produce a shorter block")
    func heightGrowsMonotonicallyWithLineCount() {
        let one = height("SELECT 1;")
        let three = height("SELECT 1;\nSELECT 2;\nSELECT 3;")

        #expect(three > one)
    }

    @Test("A wrapping line is taller than the same text on a wide layout")
    func wrappingIsAccountedFor() {
        let line = String(repeating: "SELECT column_name FROM some_table ", count: 6)

        #expect(height(line, width: 200) > height(line, width: 1_200))
    }

    @Test("A zero width falls back to the line-count estimate")
    func zeroWidthUsesFallback() {
        let code = "SELECT 1;\nSELECT 2;"

        #expect(height(code, width: 0) == CodeBlockHeightEstimator.fallbackHeight(for: code, font: Self.font))
    }

    @Test("The estimate covers what the editor actually lays out at its line height multiple")
    func estimateCoversEditorLineHeight() {
        let lineCount = 10
        let code = (1...lineCount).map { "SELECT \($0);" }.joined(separator: "\n")
        let editorContent = CGFloat(lineCount) * CodeBlockHeightEstimator.editorLineHeight(for: Self.font)

        #expect(height(code) >= editorContent)
    }

    @Test("The editor line height applies the multiple to the font's own metrics")
    func editorLineHeightAppliesTheMultiple() {
        let raw: CGFloat = Self.font.ascender - Self.font.descender + Self.font.leading

        #expect(CodeBlockHeightEstimator.editorLineHeight(for: Self.font) == raw * CodeBlockHeightEstimator.lineHeightMultiple)
        #expect(CodeBlockHeightEstimator.extraLineSpacing(for: Self.font) >= 0)
    }

    @Test("The estimate is never shorter than a plain unscaled text measurement")
    func estimateIsNeverShorterThanPlainText() {
        let code = (1...12).map { "SELECT column_\($0) FROM some_table;" }.joined(separator: "\n")
        let plain = (code as NSString).boundingRect(
            with: CGSize(width: CGFloat(464), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font]
        ).height

        #expect(height(code) >= plain)
    }
}
