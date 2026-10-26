//
//  NSWindowNextFrameTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct NSWindowNextFrameTests {
    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("The wait ends whether or not the window ever draws a frame")
    func waitAlwaysEnds() async {
        let clock = ContinuousClock()
        let hidden = Self.window()
        let shown = Self.window()
        shown.orderFront(nil)
        defer { shown.orderOut(nil) }

        let elapsed = await clock.measure {
            await hidden.nextFrame(limit: .milliseconds(50))
            await shown.nextFrame(limit: .milliseconds(50))
            await shown.nextFrame(limit: .milliseconds(50))
        }

        #expect(elapsed < .seconds(5))
    }
}
