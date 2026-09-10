//
//  AcknowledgementsWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the open source acknowledgements. One instance is kept for the app's lifetime, the
/// same shape `SettingsWindowController` uses for the other utility window.
@MainActor
internal final class AcknowledgementsWindowController: NSWindowController {
    private static var shared: AcknowledgementsWindowController?
    private static let windowSize = NSSize(width: 820, height: 540)

    internal static func present() {
        let controller = shared ?? AcknowledgementsWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init() {
        let hosting = NSHostingController(
            rootView: AcknowledgementsView(inventory: ThirdPartyLicenseInventory.bundled())
        )
        hosting.preferredContentSize = Self.windowSize

        let window = NSWindow.titled(String(localized: "Acknowledgements"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.acknowledgements)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isRestorable = false
        window.setContentSize(Self.windowSize)
        window.applyAutosaveName(WindowIdentifier.acknowledgements)
        self.init(window: window)
    }
}
