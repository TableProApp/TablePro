//
//  EditorTabStripWindowDragTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@Suite("Editor tab strip window drag", .serialized)
@MainActor
struct EditorTabStripWindowDragTests {
    private static let tabCount = 3

    @Test("A press anywhere on a tab reaches a view that never moves the window")
    func pressOnATabNeverMovesTheWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        let strip = try showStrip(in: fixture)

        #expect(strip.interaction.displayedIds.count == Self.tabCount)
        for index in strip.interaction.displayedIds.indices {
            let placement = try #require(strip.interaction.run.placement(at: index))
            for x in [placement.frame.minX + 1, placement.frame.midX, placement.frame.maxX - 1] {
                let hit = viewUnderPress(atContent: CGPoint(x: x, y: placement.frame.midY), of: strip, in: fixture)
                #expect(hit === strip, "Tab \(index) at \(x) reached \(String(describing: hit))")
                #expect(hit?.mouseDownCanMoveWindow == false, "Tab \(index) at \(x) can move the window")
            }
        }
    }

    @Test("The titlebar above the toolbar items still moves the window")
    func titlebarStillMovesTheWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        let strip = try showStrip(in: fixture)

        let point = CGPoint(x: fixture.window.frame.width / 2, y: fixture.window.frame.height - 2)
        let hit = try #require(fixture.themeFrame?.hitTest(point))
        #expect(hit !== strip)
        #expect(hit.mouseDownCanMoveWindow, "\(hit) takes the press from the window")
    }

    private func showStrip(in fixture: OffscreenConnectionWindow) throws -> EditorTabInteractionView {
        let pane = fixture.workspace.panes.tabStrip
        let strip = try #require(pane.view as? EditorTabInteractionView)
        pane.interaction.adopt(tabIds: (0 ..< Self.tabCount).map { _ in UUID() }, overflow: .scroll)
        fixture.split.tabStripAccessory.setBandVisible(true)
        fixture.window.layoutIfNeeded()
        return strip
    }

    private func viewUnderPress(
        atContent point: CGPoint,
        of strip: EditorTabInteractionView,
        in fixture: OffscreenConnectionWindow
    ) -> NSView? {
        let local = CGPoint(
            x: point.x - strip.interaction.contentOffset
                + EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding,
            y: point.y + EditorTabStripLayout.trackPadding
        )
        return fixture.themeFrame?.hitTest(strip.convert(local, to: nil))
    }
}
