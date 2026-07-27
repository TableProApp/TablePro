//
//  CompareSyncCloseGuard.swift
//  TablePro
//
//  Refuses to close the window while a script is being applied, so a run is not
//  abandoned halfway without the user saying so. The delegate forwards every
//  other message to whatever delegate SwiftUI installed.
//

import AppKit
import SwiftUI

internal struct CompareSyncCloseGuard: NSViewRepresentable {
    internal let session: CompareSyncSession

    internal func makeNSView(context: Context) -> NSView {
        let view = CloseGuardHostView()
        view.session = session
        return view
    }

    internal func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CloseGuardHostView)?.session = session
    }
}

private final class CloseGuardHostView: NSView {
    var session: CompareSyncSession? {
        didSet { proxy.session = session }
    }

    private let proxy = CloseGuardDelegateProxy()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        guard !(window.delegate is CloseGuardDelegateProxy) else { return }
        proxy.forwarding = window.delegate
        window.delegate = proxy
    }
}

private final class CloseGuardDelegateProxy: NSObject, NSWindowDelegate {
    weak var forwarding: NSWindowDelegate?
    weak var session: CompareSyncSession?

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwarding?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwarding?.responds(to: aSelector) == true { return forwarding }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session, session.activity == .applying else {
            return forwarding?.windowShouldClose?(sender) ?? true
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "A sync is still running")
        alert.informativeText = String(
            localized: "Closing now stops the run between statements. Statements that already ran stay applied."
        )
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Stop and Close"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }

        session.cancelRunningWork()
        return true
    }
}
