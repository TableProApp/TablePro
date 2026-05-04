//
//  WindowRestorationDisabler.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor [weak view] in
            view?.window?.isRestorable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
