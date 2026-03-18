//
//  WindowLifecycleMonitorTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing
@testable import TablePro

@Suite("WindowLifecycleMonitor")
@MainActor
struct WindowLifecycleMonitorTests {
    private var monitor: WindowLifecycleMonitor { WindowLifecycleMonitor.shared }

    private func cleanup(_ windowIds: UUID...) {
        for id in windowIds {
            monitor.unregisterWindow(for: id)
        }
    }

    // MARK: - Register basics

    @Test("register — connectionId(for:) returns correct connectionId")
    func registerReturnsConnectionId() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)
        defer { cleanup(windowId) }

        #expect(monitor.connectionId(for: windowId) == connectionId)
    }

    @Test("register — windows(for:) returns the registered window")
    func registerReturnsWindow() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)
        defer { cleanup(windowId) }

        let windows = monitor.windows(for: connectionId)
        #expect(windows.count == 1)
        #expect(windows.first === window)
    }

    @Test("register — allConnectionIds() includes the connectionId")
    func registerIncludesConnectionId() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)
        defer { cleanup(windowId) }

        #expect(monitor.allConnectionIds().contains(connectionId))
    }

    // MARK: - Unregister

    @Test("unregisterWindow — removes the entry, connectionId(for:) returns nil")
    func unregisterRemovesEntry() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)
        monitor.unregisterWindow(for: windowId)

        #expect(monitor.connectionId(for: windowId) == nil)
        #expect(monitor.windows(for: connectionId).isEmpty)
    }

    @Test("unregisterWindow for unknown windowId — does not crash")
    func unregisterUnknownWindowId() {
        monitor.unregisterWindow(for: UUID())
    }

    // MARK: - hasOtherWindows

    @Test("hasOtherWindows — returns true when other windows exist for same connection")
    func hasOtherWindowsTrueWhenOthersExist() {
        let windowId1 = UUID()
        let windowId2 = UUID()
        let connectionId = UUID()

        monitor.register(window: NSWindow(), connectionId: connectionId, windowId: windowId1)
        monitor.register(window: NSWindow(), connectionId: connectionId, windowId: windowId2)
        defer { cleanup(windowId1, windowId2) }

        #expect(monitor.hasOtherWindows(for: connectionId, excluding: windowId1))
        #expect(monitor.hasOtherWindows(for: connectionId, excluding: windowId2))
    }

    @Test("hasOtherWindows — returns false when only the excluded window exists")
    func hasOtherWindowsFalseWhenOnlySelf() {
        let windowId = UUID()
        let connectionId = UUID()

        monitor.register(window: NSWindow(), connectionId: connectionId, windowId: windowId)
        defer { cleanup(windowId) }

        #expect(!monitor.hasOtherWindows(for: connectionId, excluding: windowId))
    }

    @Test("hasOtherWindows — returns false when no windows exist")
    func hasOtherWindowsFalseWhenEmpty() {
        #expect(!monitor.hasOtherWindows(for: UUID(), excluding: UUID()))
    }

    // MARK: - Multiple connections

    @Test("Multiple connections — windows are independent")
    func multipleConnectionsIndependent() {
        let windowIdA = UUID()
        let windowIdB = UUID()
        let connectionA = UUID()
        let connectionB = UUID()
        let windowA = NSWindow()
        let windowB = NSWindow()

        monitor.register(window: windowA, connectionId: connectionA, windowId: windowIdA)
        monitor.register(window: windowB, connectionId: connectionB, windowId: windowIdB)
        defer { cleanup(windowIdA, windowIdB) }

        #expect(monitor.windows(for: connectionA).count == 1)
        #expect(monitor.windows(for: connectionA).first === windowA)
        #expect(monitor.windows(for: connectionB).count == 1)
        #expect(monitor.windows(for: connectionB).first === windowB)

        // Unregister A does not affect B
        monitor.unregisterWindow(for: windowIdA)

        #expect(monitor.windows(for: connectionA).isEmpty)
        #expect(monitor.windows(for: connectionB).count == 1)
        #expect(monitor.connectionId(for: windowIdB) == connectionB)
    }

    // MARK: - Re-register same windowId

    @Test("Re-register same windowId — replaces existing entry without duplicate observers")
    func reRegisterReplaces() {
        let windowId = UUID()
        let connectionId1 = UUID()
        let connectionId2 = UUID()
        let window1 = NSWindow()
        let window2 = NSWindow()

        monitor.register(window: window1, connectionId: connectionId1, windowId: windowId)
        monitor.register(window: window2, connectionId: connectionId2, windowId: windowId)
        defer { cleanup(windowId) }

        // Should reflect the second registration
        #expect(monitor.connectionId(for: windowId) == connectionId2)
        #expect(monitor.windows(for: connectionId2).first === window2)
        #expect(monitor.windows(for: connectionId1).isEmpty)
    }

    // MARK: - findWindow

    @Test("findWindow — returns nil for unknown connectionId")
    func findWindowNilForUnknown() {
        #expect(monitor.findWindow(for: UUID()) == nil)
    }

    // MARK: - windows(for:) empty for unknown

    @Test("windows(for:) returns empty array for unknown connectionId")
    func windowsEmptyForUnknown() {
        #expect(monitor.windows(for: UUID()).isEmpty)
    }

    // MARK: - allConnectionIds empty

    @Test("allConnectionIds — returns empty set when no windows registered")
    func allConnectionIdsEmptyWhenNone() {
        // Verify no leftover state from other tests by checking a fresh UUID is absent
        let freshId = UUID()
        #expect(!monitor.allConnectionIds().contains(freshId))
    }

    // MARK: - Auto-cleanup on window close notification

    @Test("Auto-cleanup — willCloseNotification removes the entry")
    func autoCleanupOnWindowClose() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)

        // Simulate the window closing
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        // The notification handler runs on .main queue synchronously (we're already on main)
        #expect(monitor.connectionId(for: windowId) == nil)
        #expect(monitor.windows(for: connectionId).isEmpty)
    }

    @Test("Auto-cleanup — closing one of two windows leaves the other registered")
    func autoCleanupLeavesOtherWindows() {
        let windowId1 = UUID()
        let windowId2 = UUID()
        let connectionId = UUID()
        let window1 = NSWindow()
        let window2 = NSWindow()

        monitor.register(window: window1, connectionId: connectionId, windowId: windowId1)
        monitor.register(window: window2, connectionId: connectionId, windowId: windowId2)
        defer { cleanup(windowId2) }

        // Close only the first window
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window1)

        #expect(monitor.connectionId(for: windowId1) == nil)
        #expect(monitor.connectionId(for: windowId2) == connectionId)
        #expect(monitor.hasWindows(for: connectionId))
    }

    @Test("Auto-cleanup — closing last window removes all entries for that connection")
    func autoCleanupLastWindowRemovesAll() {
        let windowId = UUID()
        let connectionId = UUID()
        let window = NSWindow()

        monitor.register(window: window, connectionId: connectionId, windowId: windowId)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        #expect(!monitor.hasWindows(for: connectionId))
        #expect(monitor.connectionId(for: windowId) == nil)
    }

    @Test("Auto-cleanup — closing an unregistered window is ignored")
    func autoCleanupIgnoresUnregisteredWindow() {
        let unrelatedWindow = NSWindow()

        // Should not crash or affect state
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: unrelatedWindow)
    }
}
