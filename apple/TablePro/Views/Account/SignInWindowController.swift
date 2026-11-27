//
//  SignInWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

// The "Sign in to TablePro" window: once at first launch (SignInPrompt), and whenever a gate or the welcome
// window asks for a sign-in. Its size comes from the view, so it saves no frame.
@MainActor
internal final class SignInWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SignInWindowController?
    private var model: SignInModel?

    private final class WindowBox {
        weak var window: NSWindow?
    }

    internal static func present(
        purpose: SignInView.Purpose = .requested,
        entersCompanyServer: Bool = false,
        services: AccountServices = .shared
    ) {
        let controller = shared ?? SignInWindowController(
            purpose: purpose,
            entersCompanyServer: entersCompanyServer,
            services: services
        )
        shared = controller
        if entersCompanyServer {
            controller.model?.showCompanyServer()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private convenience init(purpose: SignInView.Purpose, entersCompanyServer: Bool, services: AccountServices) {
        let box = WindowBox()
        let model = SignInModel(services: services, entersCompanyServer: entersCompanyServer)
        let view = SignInView(
            model: model,
            purpose: purpose,
            authenticator: { WebAuthenticationSessionAuthenticator(anchor: { box.window }) },
            onClose: { box.window?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow.titled(String(localized: "Sign in to TablePro"), contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.signIn)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isRestorable = false
        window.center()
        box.window = window
        self.init(window: window)
        self.model = model
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if Self.shared === self {
            Self.shared = nil
        }
    }
}
