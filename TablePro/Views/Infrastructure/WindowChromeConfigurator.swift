//
//  WindowChromeConfigurator.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct WindowChromeConfigurator: NSViewRepresentable {
    var restorable: Bool = true
    var fullScreenable: Bool = true
    var hideMiniaturizeButton: Bool = false
    var hideZoomButton: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = ChromeHostView()
        view.apply(configuration: self)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? ChromeHostView else { return }
        host.apply(configuration: self)
    }
}

private final class ChromeHostView: NSView {
    private var pending: WindowChromeConfigurator?

    func apply(configuration: WindowChromeConfigurator) {
        pending = configuration
        applyToCurrentWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToCurrentWindow()
    }

    private func applyToCurrentWindow() {
        guard let window, let config = pending else { return }

        window.isRestorable = config.restorable

        if config.fullScreenable {
            window.collectionBehavior.remove(.fullScreenNone)
        } else {
            window.collectionBehavior.insert(.fullScreenNone)
        }

        window.standardWindowButton(.miniaturizeButton)?.isHidden = config.hideMiniaturizeButton
        window.standardWindowButton(.zoomButton)?.isHidden = config.hideZoomButton
    }
}
