//
//  NSWindowNextFrameTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTestSupport
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

    @Test("A wait that ends at its limit leaves no display link behind")
    func timedOutWaitReleasesItsObserver() async {
        guard #available(macOS 14.0, *) else { return }
        let window = Self.window()
        window.orderFront(nil)
        window.orderOut(nil)
        let before = FirstFrameObserver.liveCount

        await window.nextFrame(limit: .milliseconds(30))

        #expect(FirstFrameObserver.liveCount == before)
    }

    @Test("Work after the committed turn never runs in the turn that asked for it")
    func committedTurnRunsLater() async throws {
        var ran = false

        CommittedTurn.after { ran = true }

        #expect(!ran)
        try await waitUntil { ran }
    }
}
