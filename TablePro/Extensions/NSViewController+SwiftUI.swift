//
//  NSViewController+SwiftUI.swift
//  TablePro
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

extension NSViewController {
    func presentAsSheet<Content: View>(_ swiftUIView: Content, onSave: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let hostingController = KeyboardHandlingHostingController(rootView: swiftUIView)
        hostingController.onSave = onSave
        hostingController.onCancel = onCancel ?? { [weak hostingController] in
            hostingController?.dismiss(nil)
        }
        presentAsSheet(hostingController)
    }
}

private class KeyboardHandlingHostingController<Content: View>: NSHostingController<Content> {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)

        if commandPressed && (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)) {
            onSave?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}
