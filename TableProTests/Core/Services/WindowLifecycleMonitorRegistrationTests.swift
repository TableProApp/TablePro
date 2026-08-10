//
//  WindowLifecycleMonitorRegistrationTests.swift
//  TableProTests
//
//  A window id belongs to the content mounted in the window, so rebuilding that content registers the
//  same NSWindow again under a new id. Keeping both entries made one window count as two, which is
//  what stopped a reconnected window from restoring its tabs: the restore stands down on a sibling.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Window lifecycle monitor registration", .serialized)
@MainActor
struct WindowLifecycleMonitorRegistrationTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
    }

    @Test("Re-registering one window under a new id leaves it a single window")
    func rereigsteringSupersedesTheOldEntry() {
        let monitor = WindowLifecycleMonitor.shared
        let connectionId = UUID()
        let window = makeWindow()
        let firstId = UUID()
        let secondId = UUID()
        defer {
            monitor.unregisterWindow(for: firstId)
            monitor.unregisterWindow(for: secondId)
        }

        monitor.register(window: window, connectionId: connectionId, windowId: firstId)
        monitor.register(window: window, connectionId: connectionId, windowId: secondId)

        #expect(monitor.windows(for: connectionId).count == 1)
        #expect(monitor.window(for: secondId) === window)
        #expect(monitor.window(for: firstId) == nil)
    }

    @Test("Two genuine windows on one connection still see each other")
    func distinctWindowsRemainSiblings() {
        let monitor = WindowLifecycleMonitor.shared
        let connectionId = UUID()
        let first = makeWindow()
        let second = makeWindow()
        let firstId = UUID()
        let secondId = UUID()
        defer {
            monitor.unregisterWindow(for: firstId)
            monitor.unregisterWindow(for: secondId)
        }

        monitor.register(window: first, connectionId: connectionId, windowId: firstId)
        monitor.register(window: second, connectionId: connectionId, windowId: secondId)

        #expect(monitor.windows(for: connectionId).count == 2)
        #expect(monitor.window(for: firstId) === first)
        #expect(monitor.window(for: secondId) === second)
    }
}
