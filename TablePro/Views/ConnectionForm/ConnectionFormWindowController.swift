//
//  ConnectionFormWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts `ConnectionFormView` in an AppKit window so the app no longer needs a SwiftUI
/// scene for it. The registry keyed by request is the behaviour `WindowGroup(for:)` gave
/// for free: two windows on the same request would each own a `ConnectionFormCoordinator`
/// writing the same stored connection, so a repeat open focuses the window that exists.
@MainActor
internal final class ConnectionFormWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [ConnectionFormRequest: ConnectionFormWindowController] = [:]

    internal static func present(_ request: ConnectionFormRequest) {
        let controller = controllers[request] ?? ConnectionFormWindowController(request: request)
        controllers[request] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private static func close(_ request: ConnectionFormRequest) {
        controllers[request]?.close()
    }

    private static func initialTitle(for request: ConnectionFormRequest) -> String {
        switch request {
        case .edit: return String(localized: "Edit Connection")
        case .create: return String(localized: "New Connection")
        }
    }

    private convenience init(request: ConnectionFormRequest) {
        /// `dismiss()` is inert in a view hosted as a window's content view controller, so the
        /// form's save, cancel and delete paths need an explicit way to close the window.
        let content = ConnectionFormView(
            request: request,
            close: { ConnectionFormWindowController.close(request) }
        )
        .environment(\.appServices, .live)
        let hosting = NSHostingController(rootView: content)
        /// A standalone window wants the content's minimum to become the window's, unlike a
        /// split pane's host, where the same minimum would pin the window's dividers.
        hosting.sizingOptions = [.minSize]

        let window = NSWindow.titled(Self.initialTitle(for: request), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.connectionForm)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.setContentSize(NSSize(width: 820, height: 600))
        window.setFrameAutosaveName(WindowIdentifier.connectionForm)
        self.init(window: window)
        window.delegate = self
    }

    internal func windowWillClose(_ notification: Notification) {
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }
}
