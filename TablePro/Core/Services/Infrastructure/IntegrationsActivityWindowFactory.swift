//
//  IntegrationsActivityWindowFactory.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal enum IntegrationsActivityWindowFactory {
    private static let identifier = NSUserInterfaceItemIdentifier("integrations-activity")
    private static let autosaveName: NSWindow.FrameAutosaveName = "IntegrationsActivityWindow"
    private static let defaultSize = NSSize(width: 960, height: 600)
    private static let minimumSize = NSSize(width: 720, height: 420)

    internal static func openOrFront() {
        if let existing = existingWindow() {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func existingWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier == identifier }
    }

    private static func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: IntegrationsActivityView())
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = identifier
        window.title = String(localized: "Integrations Activity")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.minSize = minimumSize
        window.applyAutosaveName(autosaveName)
        return window
    }
}
