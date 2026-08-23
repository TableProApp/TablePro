//
//  GutterNumberOffsetTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// Where the line number is actually painted, read back off the gutter.
///
/// A width assertion cannot tell a wide gutter apart from one drawing its number in the wrong place, and the report
/// here was about the gap before the digit rather than the column's total width. This rasterises the gutter and finds
/// the first column the number reaches.
@MainActor
struct GutterNumberOffsetTests {
    private func controller(fitsContent: Bool) -> TextViewController {
        let controller = Mock.textViewController(theme: Mock.theme())
        controller.loadView()
        controller.textView.string = "UPDATE `Album` SET `Title` = 'sa' WHERE `AlbumId` = '6';"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 800, height: 200))
        controller.gutterView.fitsContent = fitsContent
        controller.gutterView.updateWidthIfNeeded()
        controller.gutterView.frame.size.height = 200
        return controller
    }

    /// The leftmost point of the gutter that the line number paints, or `nil` when nothing was drawn.
    private func firstInkedColumn(_ gutter: GutterView) -> CGFloat? {
        let bounds = CGRect(x: 0, y: 0, width: gutter.frame.width, height: 40)
        guard bounds.width > 0, let rep = gutter.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        gutter.cacheDisplay(in: bounds, to: rep)

        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.5 && luminance < 0.75 {
                    return CGFloat(x) / CGFloat(rep.pixelsWide) * bounds.width
                }
            }
        }
        return nil
    }

    @Test("A gutter that fits its content paints the line number at the very start")
    func fittedNumberStartsAtTheEdge() throws {
        let column = try #require(
            firstInkedColumn(controller(fitsContent: true).gutterView),
            "The gutter drew no line number"
        )

        #expect(
            column < 4,
            "A one line listing has no window edge and no missing digits to pay for, got \(column)pt of blank"
        )
    }

    @Test("A window's gutter keeps its margin and its room to grow")
    func windowGutterKeepsItsMargin() throws {
        let column = try #require(
            firstInkedColumn(controller(fitsContent: false).gutterView),
            "The gutter drew no line number"
        )

        #expect(
            column > 25,
            "A window gutter reserves a 20pt margin and room for three digits, got \(column)pt of blank"
        )
    }
}
