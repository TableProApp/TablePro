//
//  BinaryValueViewerWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class BinaryValueViewerWindowController: ValueViewerWindowController {
    static func open(data: Data, format: BinaryValueFormat, columnName: String?) {
        let title: String
        if let columnName {
            title = String(format: String(localized: "%@: %@"), format.displayName, columnName)
        } else {
            title = format.displayName
        }

        let controller = BinaryValueViewerWindowController()
        controller.present(
            identifier: "binary-value-viewer",
            title: title,
            autosaveName: "BinaryValueViewerWindow"
        ) { _ in
            BinaryValueViewerView(data: data, format: format)
        }
    }
}
