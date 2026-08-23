//
//  LineFoldAccessibilityTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// The fold chevrons are drawn rather than hosted as views, which is what keeps scrolling a long document cheap. A
/// drawn control is not a control as far as assistive technology is concerned unless the view says so, so the ribbon
/// publishes one element per chevron and those elements have to actually work.
@MainActor
struct LineFoldAccessibilityTests {
    private let controller: TextViewController
    private let ribbon: LineFoldRibbonView
    private let model: LineFoldModel

    init() throws {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = "A\nB\nC\nD\nE\nF\n"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        ribbon = LineFoldRibbonView(controller: controller)
        ribbon.frame = NSRect(x: 0, y: 0, width: 14, height: 1000)
        model = try #require(ribbon.model)
        model.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: [LineFoldStorage.RawFold(depth: 1, range: 1..<6)]
        )
    }

    private func elements() -> [FoldDisclosureElement] {
        (ribbon.accessibilityChildren() as? [FoldDisclosureElement]) ?? []
    }

    @Test("Every chevron on screen is one accessibility element")
    func chevronsArePublished() {
        #expect(elements().count == 1)
    }

    @Test("A fold reports itself as a disclosure triangle, the way the rest of macOS does")
    func elementUsesTheDisclosureRole() throws {
        let element = try #require(elements().first)

        #expect(element.accessibilityRole() == .disclosureTriangle)
        #expect(element.accessibilityLabel()?.isEmpty == false)
    }

    @Test("The element's value follows whether the block is collapsed")
    func valueFollowsCollapsedState() throws {
        let fold = try #require(model.getFolds(in: 0..<controller.textView.textStorage.length).first)
        let element = try #require(elements().first)

        #expect(element.accessibilityValue() as? Int == 0)

        model.setCollapsed(true, for: fold)

        #expect(try #require(elements().first).accessibilityValue() as? Int == 1)
    }

    @Test("Pressing the element folds the block, the same call the pointer makes")
    func pressTogglesTheFold() throws {
        let element = try #require(elements().first)

        #expect(element.accessibilityPerformPress())

        let fold = try #require(model.getFolds(in: 0..<controller.textView.textStorage.length).first)
        #expect(model.isCollapsed(fold))
    }

    @Test("A document with no folds publishes no elements")
    func noFoldsNoElements() {
        model.foldCache = LineFoldStorage(documentLength: controller.textView.textStorage.length, folds: [])

        #expect(elements().isEmpty)
    }
}
