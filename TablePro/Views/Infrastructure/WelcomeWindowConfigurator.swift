//
//  WelcomeWindowConfigurator.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct WelcomeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor [weak view] in
            guard let window = view?.window else { return }
            window.isRestorable = false
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
