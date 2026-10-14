//
//  TrailingEdgeClickTests.swift
//  TableProEditorKitTests
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// #2156: a view floating over the editor's trailing strip answered hit testing there and dropped every click, so
/// clicking past the end of a line did nothing.
@MainActor
@Suite("A click on the editor's trailing edge")
struct TrailingEdgeClickTests {
    @Test("Lands in the text view and puts the caret at the end of the clicked line")
    func trailingClickReachesTheLineEnd() throws {
        let firstLine = "SELECT 1;"
        let controller = Mock.loadedTextViewController(string: firstLine + "\nSELECT 22;")
        let textView = try #require(controller.textView)
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        let line = try #require(textView.layoutManager.textLineForIndex(0))

        // Clear of a legacy scroller, which a mouse-attached Mac draws along the same edge.
        let point = NSPoint(x: textView.visibleRect.maxX - 40, y: line.yPos + line.height / 2)
        try #require(point.x > 200, "The editor must be wide enough for the strip to sit past the text")

        let hit = controller.view.hitTest(textView.convert(point, to: controller.view))
        #expect(hit === textView || hit?.isDescendant(of: textView) == true, "Got \(String(describing: hit))")
        #expect(textView.layoutManager.textOffsetAtPoint(point) == (firstLine as NSString).length)
    }
}
