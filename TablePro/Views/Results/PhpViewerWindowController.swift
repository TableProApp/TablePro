//
//  PhpViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class PhpViewerWindowController: ValueViewerWindowController {
    static func open(text: String?, columnName: String?) {
        let title: String
        if let columnName {
            title = String(format: String(localized: "PHP: %@"), columnName)
        } else {
            title = String(localized: "PHP Viewer")
        }

        let controller = PhpViewerWindowController()
        controller.present(
            identifier: "php-viewer",
            title: title,
            autosaveName: "PhpViewerWindow"
        ) { dismiss in
            PhpViewerView(rawValue: text ?? "", onDismiss: dismiss, onPopOut: nil)
        }
    }
}
