//
//  IntegrationsActivityWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts `IntegrationsActivityView` in an AppKit window so the app no longer needs a SwiftUI
/// scene for it. One instance is kept for the app's lifetime, matching the single-window scene
/// it replaces.
@MainActor
internal final class IntegrationsActivityWindowController: NSWindowController {
    private static var shared: IntegrationsActivityWindowController?

    internal static func present() {
        let controller = shared ?? IntegrationsActivityWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private convenience init() {
        let content = IntegrationsActivityView()
            .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A standalone window wants the content's minimum to become the window's, unlike a
        /// split pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]

        let window = NSWindow.titled(String(localized: "Integrations Activity"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.integrationsActivity)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 600))
        window.setFrameAutosaveName(WindowIdentifier.integrationsActivity)
        self.init(window: window)
    }
}
