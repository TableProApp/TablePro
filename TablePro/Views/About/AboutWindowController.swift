//
//  AboutWindowController.swift
//  TablePro
//
//  Singleton controller for the custom About window.
//

import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var panel: NSPanel?

    private init() {}

    func showAboutPanel() {
        if let existingPanel = panel {
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("about")
        panel.title = String(localized: "About TablePro")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenNone]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: AboutView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel = nil
            }
        }
    }
}
