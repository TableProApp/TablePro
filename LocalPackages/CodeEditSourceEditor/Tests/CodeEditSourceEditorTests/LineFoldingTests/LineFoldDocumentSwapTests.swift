//
//  LineFoldDocumentSwapTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// A recalculation deliberately carries collapse state across by depth and start offset, which is what keeps a region
/// folded while the reader types above it. Replacing the document makes those offsets meaningless, so the collapse
/// state has to go with the document that owned it.
@MainActor
struct LineFoldDocumentSwapTests {
    private let controller: TextViewController
    private let model: LineFoldModel

    init() throws {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.loadView()
        controller.textView.string = "A\nB\nC\nD\nE\nF\n"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        model = try #require(controller.gutterView.foldingRibbon.model)
        model.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: [LineFoldStorage.RawFold(depth: 1, range: 1..<6)]
        )
    }

    private func currentFold() throws -> FoldRange {
        try #require(model.getFolds(in: 0..<controller.textView.textStorage.length).first)
    }

    @Test("Replacing the document drops the folds it had")
    func documentSwapDropsCollapseState() throws {
        model.setCollapsed(true, for: try currentFold())
        #expect(!model.collapsedFoldRanges().isEmpty)

        controller.setText("X\nY\nZ\n")

        #expect(
            model.collapsedFoldRanges().isEmpty,
            "One document's collapsed regions must not reappear in the next wherever the offsets line up"
        )
    }

    @Test("Replacing the document removes the placeholders standing in for the old text")
    func documentSwapRemovesPlaceholders() throws {
        model.setCollapsed(true, for: try currentFold())
        let attachments = controller.textView.layoutManager.attachments
        #expect(!attachments.isEmpty)

        controller.setText("X\nY\nZ\n")

        #expect(
            controller.textView.layoutManager.attachments.isEmpty,
            "An attachment is a range in a storage that no longer exists"
        )
    }

    @Test("Replacing the document is not reported as the reader folding anything")
    func documentSwapPostsNothing() throws {
        model.setCollapsed(true, for: try currentFold())

        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: TextViewController.foldStateDidChangeNotification,
            object: controller,
            queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.setText("X\nY\nZ\n")

        #expect(posted == 0, "A listener that saved this as the reader's fold state would save it onto the wrong tab")
    }

    @Test("Replacing the document drops a hover left over from the old one")
    func documentSwapClearsHover() throws {
        let fold = try currentFold()
        model.setGutterHover(fold)
        #expect(model.hoveredFold != nil)

        controller.setText("X\nY\nZ\n")

        #expect(model.hoveredFold == nil)
    }
}
