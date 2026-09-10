//
//  LineFoldCollapsePathTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// A fold can be toggled from the gutter's chevron or by clicking the placeholder that stands in for it, and the two
/// used to record the change in different ways: only one of them relaid out the text and redrew the gutter. Both now
/// end at the same commit, so the cache, the layout and anything listening cannot disagree about what is folded.
@MainActor
struct LineFoldCollapsePathTests {
    private let controller: TextViewController
    private let ribbon: LineFoldRibbonView
    private let model: LineFoldModel

    init() throws {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = "A\nB\nC\nD\nE\nF\n"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        ribbon = LineFoldRibbonView(controller: controller)
        model = try #require(ribbon.model)
        model.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: [LineFoldStorage.RawFold(depth: 1, range: 1..<6)]
        )
    }

    private func currentFold() throws -> FoldRange {
        try #require(model.getFolds(in: 0..<controller.textView.textStorage.length).first)
    }

    @Test("Clicking a placeholder records the expansion the same way the chevron does")
    func discardingAPlaceholderExpandsTheFold() throws {
        model.setCollapsed(true, for: try currentFold())
        #expect(model.isCollapsed(try currentFold()))

        model.placeholderDiscarded(fold: try currentFold())

        #expect(model.isCollapsed(try currentFold()) == false)
    }

    @Test("Both routes post the fold change, so persisted tab state stays in step")
    func bothRoutesPostTheNotification() throws {
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: TextViewController.foldStateDidChangeNotification,
            object: controller,
            queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        model.setCollapsed(true, for: try currentFold())
        model.placeholderDiscarded(fold: try currentFold())

        #expect(posted == 2)
    }

    @Test("Tearing the model down releases the pointer tracking it owns")
    func destroyReleasesTracking() throws {
        let textView = try #require(controller.textView)
        #expect(textView.trackingAreas.isEmpty == false, "The tracker installs its area on the text view")

        model.destroy()

        #expect(textView.trackingAreas.isEmpty, "A tracking area must not outlive the object it names as its owner")
    }

    @Test("Expanding by click drops the hover, so no peek is left pointing at a placeholder that is gone")
    func discardingClearsTheHover() throws {
        let fold = try currentFold()
        model.setCollapsed(true, for: fold)
        model.setPlaceholderHover(
            LineFoldModel.PlaceholderHover(
                fold: fold,
                hit: CollapsedFoldHit(hiddenRange: fold.range, blockRange: fold.range, rect: .zero)
            )
        )
        #expect(model.hoveredFold != nil)

        model.placeholderDiscarded(fold: try currentFold())

        #expect(model.hoveredFold == nil)
    }
}
