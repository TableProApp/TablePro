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
    @Test("A press anywhere on a tab reaches a view that never moves the window")
    func pressOnATabNeverMovesTheWindow() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let ids = harness.interaction.displayedIds
        #expect(ids.count == Harness.tabCount)
        for index in ids.indices {
            let placement = try #require(harness.interaction.run.placement(at: index))
            for x in [placement.frame.minX + 1, placement.frame.midX, placement.frame.maxX - 1] {
                let hit = harness.viewUnderPress(atContent: CGPoint(x: x, y: placement.frame.midY))
                #expect(hit === harness.strip, "Tab \(index) at \(x) reached \(String(describing: hit))")
                #expect(hit?.mouseDownCanMoveWindow == false, "Tab \(index) at \(x) can move the window")
            }
        }
    }

    @Test("The titlebar above the toolbar items still moves the window")
    func titlebarStillMovesTheWindow() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let hit = try #require(harness.viewUnderPress(atWindow: CGPoint(
            x: harness.window.frame.width / 2,
            y: harness.window.frame.height - 2
        )))
        #expect(hit !== harness.strip)
        #expect(hit.mouseDownCanMoveWindow)
    }

    @MainActor
    private struct Harness {
        static let tabCount = 3

        let controller: TabWindowController
        let window: NSWindow
        let strip: EditorTabInteractionView
        let interaction: EditorTabStripInteraction
        private let split: MainSplitViewController
        private let workspace: ConnectionWorkspace

        init() throws {
            let connection = TestFixtures.makeConnection(name: "Tab strip drag")
            workspace = ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: .connecting
            )
            controller = TabWindowController(
                payload: EditorTabPayload(connectionId: connection.id),
                pinnedWindowSize: CGSize(width: 1_200, height: 800),
                adopting: workspace
            )
            window = try #require(controller.window)
            split = try #require(window.contentViewController as? MainSplitViewController)
            let pane = workspace.panes.tabStrip
            strip = try #require(pane.view as? EditorTabInteractionView)
            interaction = pane.interaction
            resetPaneLayout()
            interaction.adopt(tabIds: (0 ..< Self.tabCount).map { _ in UUID() }, overflow: .scroll)
            split.tabStripAccessory.setBandVisible(true)
            window.layoutIfNeeded()
        }

        func viewUnderPress(atWindow point: CGPoint) -> NSView? {
            window.contentView?.superview?.hitTest(point)
        }

        func viewUnderPress(atContent point: CGPoint) -> NSView? {
            let local = CGPoint(
                x: point.x - interaction.contentOffset
                    + EditorTabStripLayout.stripInset + EditorTabStripLayout.trackPadding,
                y: point.y + EditorTabStripLayout.trackPadding
            )
            return viewUnderPress(atWindow: strip.convert(local, to: nil))
        }

        private func resetPaneLayout() {
            split.sidebarSplitItem.isCollapsed = false
            split.inspectorSplitItem.isCollapsed = true
            window.layoutIfNeeded()
        }

        func tearDown() {
            resetPaneLayout()
            window.delegate = nil
            window.contentViewController = nil
            workspace.teardown()
        }
    }
}
