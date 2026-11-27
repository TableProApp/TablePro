//
//  EditorTabStripWindowDragTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@MainActor
struct EditorTabStripWindowDragTests {
    @Test("A press anywhere on a tab reaches a view that never moves the window")
    func pressOnATabNeverMovesTheWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        let strip = showStrip(in: fixture)

        #expect(strip.items.count == 3)
        for item in strip.items {
            let view = try #require(strip.itemView(for: item.id))
            for x in [view.bounds.minX + 1, view.bounds.midX, view.bounds.maxX - 1] {
                let point = view.convert(NSPoint(x: x, y: view.bounds.midY), to: nil)
                let hit = fixture.themeFrame?.hitTest(point)
                #expect(hit === view, "\(item.title) at \(x) reached \(String(describing: hit))")
                #expect(hit?.mouseDownCanMoveWindow == false, "\(item.title) at \(x) can move the window")
            }
        }
    }

    @Test("The titlebar above the toolbar items still moves the window")
    func titlebarStillMovesTheWindow() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        let strip = showStrip(in: fixture)

        let point = CGPoint(x: fixture.window.frame.width / 2, y: fixture.window.frame.height - 2)
        let hit = try #require(fixture.themeFrame?.hitTest(point))
        #expect(hit !== strip)
        #expect(hit.mouseDownCanMoveWindow, "\(hit) takes the press from the window")
    }

    private func showStrip(in fixture: OffscreenConnectionWindow) -> EditorTabStripView {
        let pane = fixture.workspace.panes.tabStrip
        pane.stripView.commands = .stub()
        pane.stripView.apply(EditorTabItem.samples(titles: ["Album", "Artist", "Customer"]))
        fixture.split.tabStripAccessory.setBandVisible(true)
        fixture.window.layoutIfNeeded()
        pane.stripView.layoutSubtreeIfNeeded()
        return pane.stripView
    }
}
