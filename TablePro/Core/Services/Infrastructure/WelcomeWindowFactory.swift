//
//  WelcomeWindowFactory.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal enum WelcomeWindowFactory {
    private static let identifier = NSUserInterfaceItemIdentifier("welcome")
    private static let autosaveName: NSWindow.FrameAutosaveName = "WelcomeWindow"
    private static let contentSize = NSSize(width: 700, height: 450)

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

    internal static func close() {
        existingWindow()?.close()
    }

    internal static func orderOut() {
        existingWindow()?.orderOut(nil)
    }

    private static func existingWindow() -> NSWindow? {
        NSApp.windows.first { AppLaunchCoordinator.isWelcomeWindow($0) }
    }

    private static func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: WelcomeWindowView())
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = identifier
        window.title = String(localized: "Welcome to TablePro")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior.insert(.fullScreenNone)
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        window.applyAutosaveName(autosaveName)
        return window
    }
}
