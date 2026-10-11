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
    private static let minimumSize = NSSize(width: 720, height: 460)

    internal static func present() {
        let controller = shared ?? AcknowledgementsWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init() {
        let inventory = ThirdPartyLicenseInventory.bundled()
        let selection = SidebarSelection<ThirdPartyComponent.ID>()
        let split = SidebarSplitViewController(
            sidebar: AcknowledgementsSidebar(inventory: inventory, selection: selection),
            detail: AcknowledgementsDetail(inventory: inventory, selection: selection),
            sidebarThickness: 220...340,
            idealSidebarThickness: 260,
            detailMinimumThickness: 500
        )

        let window = NSWindow.titled(String(localized: "Acknowledgements"), contentViewController: split)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.acknowledgements)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isRestorable = false
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.windowSize)
        window.applyAutosaveName(WindowIdentifier.acknowledgements)
        self.init(window: window)
    }
}
