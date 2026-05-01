//
//  ConnectionFormWindowFactory.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal enum ConnectionFormWindowFactory {
    private static let baseIdentifier = "connection-form"

    internal static func openOrFront(connectionId: UUID? = nil) {
        if let existing = existingWindow(for: connectionId) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(connectionId: connectionId)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    internal static func close(connectionId: UUID? = nil) {
        existingWindow(for: connectionId)?.close()
    }

    internal static func closeAll() {
        for window in NSApp.windows where AppLaunchCoordinator.isConnectionFormWindow(window) {
            window.close()
        }
    }

    private static func existingWindow(for connectionId: UUID?) -> NSWindow? {
        let target = identifier(for: connectionId)
        return NSApp.windows.first { $0.identifier?.rawValue == target }
    }

    private static func identifier(for connectionId: UUID?) -> String {
        if let connectionId {
            return "\(baseIdentifier)-\(connectionId.uuidString)"
        }
        return baseIdentifier
    }

    private static func makeWindow(connectionId: UUID?) -> NSWindow {
        let hostingController = NSHostingController(rootView: ConnectionFormView(connectionId: connectionId))
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier(identifier(for: connectionId))
        window.title = String(localized: "New Connection")
        window.styleMask = [.titled, .closable, .resizable]
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.styleMask.remove(.miniaturizable)
        window.collectionBehavior.insert(.fullScreenNone)
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}
