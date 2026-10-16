import AppKit
@testable import TablePro
import SwiftUI
import Testing

/// A List inside the pane's scrolling grouped Form had its scrolling turned off by SwiftUI, so the
/// themes below the first few rows could never be reached.
@MainActor
struct AppearancePaneListTests {
    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        var pending = [view]
        while let next = pending.popLast() {
            if let match = next as? T { found.append(match) }
            pending.append(contentsOf: next.subviews)
        }
        return found
    }

    private static func scrollEvent(over view: NSView, in window: NSWindow) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -80,
            wheel2: 0,
            wheel3: 0
        ))
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: center)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test("The Themes list scrolls on its own when it holds more themes than it shows")
    func themesListScrolls() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AppearanceSettingsView(settings: .constant(.default)))
        window.setContentSize(NSSize(width: 640, height: 520))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        defer { window.orderOut(nil) }

        let content = try #require(window.contentView)
        let table = try #require(
            Self.find(NSTableView.self, in: content).first { $0.numberOfRows > 10 },
            "The pane should show the Themes list"
        )
        let scrollView = try #require(table.enclosingScrollView)
        #expect(table.frame.height > scrollView.contentView.bounds.height, "The fixture needs more themes than fit")

        let before = scrollView.contentView.bounds.origin.y
        scrollView.scrollWheel(with: try Self.scrollEvent(over: scrollView, in: window))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(scrollView.contentView.bounds.origin.y > before, "A scroll over the list should move its rows")
        #expect(scrollView.verticalScrollElasticity != .none)
    }
}
