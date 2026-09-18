//
//  SupportWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the support screen. One instance is kept for the app's lifetime, the same shape
/// `AcknowledgementsWindowController` uses for the other utility windows.
///
/// The window takes its size from the view rather than a constant, so a longer translation gets
/// the height it needs instead of being clipped. That is also why it saves no frame: the window
/// cannot be resized, so a restored frame would be a stale size with nothing able to correct it,
/// and a translation that grew since the frame was saved would be clipped for good.
@MainActor
internal final class SupportWindowController: NSWindowController {
    private static var shared: SupportWindowController?

    internal static func present() {
        let controller = shared ?? SupportWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init() {
        let hosting = NSHostingController(rootView: SupportView())
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow.titled(String(localized: "Support TablePro"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.support)
        window.styleMask = [.titled, .closable]
        window.isRestorable = false
        window.center()
        self.init(window: window)
    }
}
