//
//  EditorTabStripPaneControllerTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct EditorTabStripPaneControllerTests {
    private final class BodyCounter {
        var count = 0
    }

    private struct CountingView: View {
        let counter: BodyCounter

        var body: some View {
            counter.count += 1
            return Color.clear
        }
    }

    private static func mount(_ pane: EditorTabStripPaneController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        pane.view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        window.contentView?.addSubview(pane.view)
        return window
    }

    @Test("A collapsed band builds no strip, and the strip it holds back appears when the band shows")
    func collapsedBandBuildsNoStrip() {
        let pane = EditorTabStripPaneController()
        let window = Self.mount(pane)
        defer {
            pane.teardown()
            window.orderOut(nil)
        }
        let counter = BodyCounter()

        pane.rootView = AnyView(CountingView(counter: counter))
        pane.view.layoutSubtreeIfNeeded()
        #expect(counter.count == 0)

        pane.isBandVisible = true
        pane.view.layoutSubtreeIfNeeded()
        #expect(counter.count > 0)
    }

    @Test("A shown band takes a new strip at once")
    func shownBandTakesTheStripAtOnce() {
        let pane = EditorTabStripPaneController()
        let window = Self.mount(pane)
        defer {
            pane.teardown()
            window.orderOut(nil)
        }
        pane.isBandVisible = true
        let counter = BodyCounter()

        pane.rootView = AnyView(CountingView(counter: counter))
        pane.view.layoutSubtreeIfNeeded()

        #expect(counter.count > 0)
    }
}
