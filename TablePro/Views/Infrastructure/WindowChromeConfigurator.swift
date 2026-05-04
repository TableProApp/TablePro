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
        let view = NSView(frame: .zero)
        let restorable = self.restorable
        let fullScreenable = self.fullScreenable
        let hideMiniaturizeButton = self.hideMiniaturizeButton
        let hideZoomButton = self.hideZoomButton
        Task { @MainActor [weak view] in
            guard let window = view?.window else { return }
            window.isRestorable = restorable
            if !fullScreenable {
                window.collectionBehavior.insert(.fullScreenNone)
            }
            if hideMiniaturizeButton {
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            }
            if hideZoomButton {
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
