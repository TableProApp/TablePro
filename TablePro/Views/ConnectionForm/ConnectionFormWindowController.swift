//
//  ConnectionFormWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Hosts the connection editor in an AppKit window so the app needs no SwiftUI scene for it.
///
/// The registry keyed by request is the behaviour `WindowGroup(for:)` gave for free: two windows on
/// the same request would each own a `ConnectionFormCoordinator` writing the same stored
/// connection, so a repeat open focuses the window that exists.
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

    /// Held for the window's lifetime: the toolbar keeps only a weak delegate reference.
    private let toolbarDelegate = ConnectionFormToolbarDelegate()

    private convenience init(request: ConnectionFormRequest) {
        /// Built here rather than inside a SwiftUI `.task`, because the sidebar and the detail
        /// column are now two separate hosting controllers and both edit the same coordinator.
        /// Read once: `consume` removes the draft, so a second call returns nil and the parsed URL
        /// would be silently dropped.
        let draft = Self.draft(for: request)
        let coordinator = ConnectionFormCoordinator(
            connectionId: request.editedConnectionId,
            initialType: draft?.type,
            initialParsedURL: draft?.parsedURL
        )
        /// `dismiss()` is inert in a view hosted as a window's content view controller, so the
        /// form's save, cancel and delete paths need an explicit way to close the window.
        coordinator.dismissAction = { ConnectionFormWindowController.close(request) }
        coordinator.start()
        coordinator.detectClipboardConnectionStringIfNeeded()

        let split = ConnectionFormSplitViewController(coordinator: coordinator)

        /// The split controller IS the content view controller, with nothing wrapped around it.
        /// That is what puts `toggleSidebar(_:)` on the responder chain for the View menu and lets
        /// AppKit supply `.sidebarTrackingSeparator`; a container in between takes both away.
        /// No `window.title` here: `NSWindow(contentViewController:)` binds the title to the
        /// controller's own, which tracks the connection's type, so writing it once would pin the
        /// generic string and the type would never reach the titlebar.
        let window = NSWindow(contentViewController: split)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.connectionForm)
        /// `.fullSizeContentView` with a transparent titlebar is what lets the sidebar run the
        /// window's full height and carry the traffic lights, the way System Settings and this
        /// app's own main window do. Without it the titlebar is an opaque band across the top and
        /// the sidebar starts underneath it, which is the part that reads as a custom control.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.setContentSize(NSSize(width: 820, height: 620))
        window.setFrameAutosaveName(WindowIdentifier.connectionForm)

        self.init(window: window)

        let toolbar = NSToolbar(identifier: ConnectionFormToolbarDelegate.identifier)
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
    }

    private static func draft(for request: ConnectionFormRequest) -> ConnectionFormDraft? {
        guard let draftId = request.draftId else { return nil }
        return ConnectionFormDraftStore.shared.consume(draftId)
    }

    internal func windowWillClose(_ notification: Notification) {
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }
}
