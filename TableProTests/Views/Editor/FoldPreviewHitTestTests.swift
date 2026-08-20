//
//  FoldPreviewHitTestTests.swift
//  TableProTests
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Fold preview hit testing")
@MainActor
struct FoldPreviewHitTestTests {
    private let script = """
    CREATE TABLE users (
        id BIGSERIAL,
        name TEXT,
        email TEXT
    );
    """

    private func makeController() -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: .init(showGutter: true, showFoldingRibbon: true)
        )
        let controller = TextViewController(
            string: script,
            language: .sql,
            configuration: configuration,
            cursorPositions: [CursorPosition(range: NSRange(location: 0, length: 0))],
            foldProvider: SQLLineFoldProvider(dialect: .postgres)
        )
        controller.loadView()
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 900, height: 600))
        return controller
    }

    private func foldAndWait(_ controller: TextViewController) async throws {
        for _ in 0..<40 {
            if !controller.foldRanges.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        controller.foldAll()
        controller.textView.layoutManager.layoutLines()
    }

    @Test("A point on the placeholder resolves to the collapsed fold")
    func hitTestFindsTheFold() async throws {
        let controller = makeController()
        try await foldAndWait(controller)

        let collapsed = try #require(controller.collapsedFoldRanges.first)
        let anchor = try #require(controller.textView.layoutManager.rectForOffset(collapsed.lowerBound))
        let point = CGPoint(x: anchor.midX + 4, y: anchor.midY)

        let hit = try #require(controller.collapsedFold(at: point), "The placeholder must be hit testable")
        #expect(hit.hiddenRange == collapsed)
        #expect(hit.rect.width > 0, "A popover cannot anchor to a zero width rect, got \(hit.rect)")
        #expect(hit.rect.height > 0, "got \(hit.rect)")

        let firstLine = try #require(controller.textView.layoutManager.textLineForOffset(collapsed.lowerBound))
        #expect(
            abs(hit.rect.minY - firstLine.yPos) < firstLine.height,
            "The anchor must sit on the collapsed line, got y \(hit.rect.minY) for a line at \(firstLine.yPos)"
        )
        #expect(controller.textView.isFlipped, "The anchor rect is in the text view's flipped space")
    }

    @Test("A point away from the placeholder resolves to nothing")
    func hitTestMissesElsewhere() async throws {
        let controller = makeController()
        try await foldAndWait(controller)

        #expect(controller.collapsedFold(at: CGPoint(x: 2, y: 2)) == nil)
    }

    @Test("The block range covers the line that opens the block")
    func blockRangeIncludesTheOpeningLine() async throws {
        let controller = makeController()
        try await foldAndWait(controller)

        let point = try #require(hitPoint(in: controller))
        let hit = try #require(controller.collapsedFold(at: point))

        #expect(hit.blockRange.lowerBound == 0, "The block starts at the top of the line that opens it")
        #expect(hit.blockRange.lowerBound < hit.hiddenRange.lowerBound)
        #expect(hit.blockRange.upperBound >= hit.hiddenRange.upperBound)

        let block = try #require(controller.documentText(in: hit.blockRange, limit: 4_000))
        #expect(
            block.contains("CREATE TABLE users ("),
            "A peek shows the whole block, not the remainder of it, got \(block)"
        )
        #expect(block.contains("BIGSERIAL"))
        #expect(block.contains("email TEXT"))
        #expect(block.contains(");"))
    }

    @Test("The hidden range still excludes the opening line")
    func hiddenRangeStaysBehindThePlaceholder() async throws {
        let controller = makeController()
        try await foldAndWait(controller)

        let point = try #require(hitPoint(in: controller))
        let hit = try #require(controller.collapsedFold(at: point))
        let hidden = try #require(controller.documentText(in: hit.hiddenRange, limit: 4_000))
        #expect(!hidden.contains("CREATE TABLE users ("))
    }

    @Test("Reading the document's text is capped")
    func documentTextIsCapped() async throws {
        let controller = makeController()
        try await foldAndWait(controller)

        let point = try #require(hitPoint(in: controller))
        let hit = try #require(controller.collapsedFold(at: point))
        let capped = try #require(controller.documentText(in: hit.blockRange, limit: 10))
        #expect((capped as NSString).length == 10)
    }

    private func hitPoint(in controller: TextViewController) -> CGPoint? {
        guard let collapsed = controller.collapsedFoldRanges.first,
              let anchor = controller.textView.layoutManager.rectForOffset(collapsed.lowerBound) else { return nil }
        return CGPoint(x: anchor.midX + 4, y: anchor.midY)
    }
}
