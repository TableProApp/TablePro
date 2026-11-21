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

    private var formCoordinator: ConnectionFormCoordinator?

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

    private convenience init(request: ConnectionFormRequest) {
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

        /// One scrolling form, no sidebar: a connection is a single object. No `window.title` here,
        /// since `NSWindow(contentViewController:)` binds the title to the controller's own, which
        /// tracks the connection's type.
        let content = ConnectionFormContentViewController(coordinator: coordinator)
        let window = NSWindow(contentViewController: content)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.connectionForm)
        window.keepsKeyViewLoopCurrent()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 480, height: 480)
        window.setContentSize(NSSize(width: 560, height: 640))
        if let autosaveName = SplitViewAutosaveName.current(WindowIdentifier.connectionForm) {
            window.setFrameAutosaveName(autosaveName)
        }

        self.init(window: window)
        self.formCoordinator = coordinator
        window.delegate = self
    }

    private static func draft(for request: ConnectionFormRequest) -> ConnectionFormDraft? {
        guard let draftId = request.draftId else { return nil }
        return ConnectionFormDraftStore.shared.consume(draftId)
    }

    internal func windowWillClose(_ notification: Notification) {
        formCoordinator?.teardownOnClose()
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }
}
