import AppKit
import ApplicationServices
@testable import TablePro
import SwiftUI
import Testing

/// A List inside the pane's scrolling grouped Form had its scrolling turned off by SwiftUI, so the
/// themes below the first few rows could never be reached.
@MainActor
struct AppearancePaneListTests {
    private struct HostedPane {
        let window: NSWindow
        let table: NSTableView
        let scrollView: NSScrollView
    }

    private static let windowTitle = "AppearancePaneListTests"

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

    private static func hostPane() throws -> HostedPane {
        let paneSize = SettingsPaneTabViewController.paneSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: paneSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = windowTitle
        // As the Settings window hosts a pane: the window keeps its size whatever the content asks.
        let hosting = NSHostingController(rootView: AppearanceSettingsView(settings: .constant(.default)))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(paneSize)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        let content = try #require(window.contentView)
        let table = try #require(
            find(NSTableView.self, in: content).first { $0.numberOfRows > 10 },
            "The pane should show the Themes list"
        )
        let scrollView = try #require(table.enclosingScrollView)
        return HostedPane(window: window, table: table, scrollView: scrollView)
    }

    private static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // The AX API reaches rows outside the visible rect, as an XCUITest snapshot or VoiceOver does;
    // accessibilityChildren() called in process stops at the visible ones.
    private static func readTree(of element: AXUIElement) -> Int {
        for attribute in [kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        }
        return elements(kAXChildrenAttribute, of: element).reduce(1) { $0 + readTree(of: $1) }
    }

    @Test("The Themes list scrolls on its own when it holds more themes than it shows")
    func themesListScrolls() throws {
        let pane = try Self.hostPane()
        defer { pane.window.orderOut(nil) }
        let scrollView = pane.scrollView
        #expect(pane.table.frame.height > scrollView.contentView.bounds.height, "The fixture needs more themes than fit")

        let before = scrollView.contentView.bounds.origin.y
        scrollView.scrollWheel(with: try Self.scrollEvent(over: scrollView, in: pane.window))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(scrollView.contentView.bounds.origin.y > before, "A scroll over the list should move its rows")
        #expect(scrollView.verticalScrollElasticity != .none)
    }

    @Test("Reading the Themes list for accessibility leaves its rows where they are")
    func themesListHoldsStillWhileAccessibilityReadsIt() throws {
        let pane = try Self.hostPane()
        pane.window.orderFront(nil)
        defer { pane.window.orderOut(nil) }
        let table = pane.table
        let clipView = pane.scrollView.contentView

        let window = try #require(
            Self.elements(kAXWindowsAttribute, of: AXUIElementCreateApplication(getpid()))
                .first { Self.title(of: $0) == Self.windowTitle },
            "The pane's window should be in the accessibility tree"
        )
        #expect(Self.readTree(of: window) > table.numberOfRows, "The read should reach every row")

        for _ in 0..<12 {
            pane.scrollView.scrollWheel(with: try Self.scrollEvent(over: pane.scrollView, in: pane.window))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            let shown = table.rows(in: clipView.documentVisibleRect)
            _ = Self.readTree(of: window)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let after = table.rows(in: clipView.documentVisibleRect)
            #expect(after.location == shown.location, "Rows \(shown) moved to \(after) while nothing scrolled")
        }
        #expect(
            table.rows(in: clipView.documentVisibleRect).contains(table.numberOfRows - 1),
            "Scrolling to the end should show the last theme"
        )
    }
}
