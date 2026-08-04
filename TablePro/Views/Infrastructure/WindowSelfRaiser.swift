//
//  WindowSelfRaiser.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct WindowSelfRaiser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        RaisingHostView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class RaisingHostView: NSView {
    private var hasRaised = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasRaised else { return }
        hasRaised = true
        window.makeKeyAndOrderFront(nil)
    }
}
